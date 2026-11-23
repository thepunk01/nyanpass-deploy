#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INSTALL_DIR=/opt/nyanpass
ENV_FILE="$INSTALL_DIR/env.sh"
LAUNCHER="$INSTALL_DIR/run.sh"
LOG_FILE=/var/log/nyanpass.log

say() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die '请使用 root 执行'
command -v python3 >/dev/null || die '需要 python3'
command -v curl >/dev/null || die '需要 curl'

read -r -p 'NyanPass 面板地址 [https://ny.atomicgcp.com]: ' PANEL
PANEL=${PANEL:-https://ny.atomicgcp.com}
[[ $PANEL == https://* ]] || die '面板必须使用 HTTPS URL'
read -r -p 'NyanPass 节点 Token: ' NODE_TOKEN
[[ -n $NODE_TOKEN ]] || die '节点 Token 不能为空'
read -r -p 'HTTP 代理 IP/域名: ' PROXY_HOST
[[ -n $PROXY_HOST ]] || die '代理主机不能为空'
read -r -p 'HTTP 代理端口 [3128]: ' PROXY_PORT
PROXY_PORT=${PROXY_PORT:-3128}
[[ $PROXY_PORT =~ ^[0-9]+$ ]] && (( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )) || die '代理端口无效'
read -r -p 'HTTP 代理用户名: ' PROXY_USER
[[ -n $PROXY_USER ]] || die '代理用户名不能为空'
read -r -s -p 'HTTP 代理密码（输入不显示）: ' PROXY_PASS
printf '\n'
[[ -n $PROXY_PASS ]] || die '代理密码不能为空'

# URL-encode credentials, without printing them.
PROXY_URL=$(PROXY_HOST="$PROXY_HOST" PROXY_PORT="$PROXY_PORT" PROXY_USER="$PROXY_USER" PROXY_PASS="$PROXY_PASS" python3 - <<'PY'
import os, urllib.parse
q=urllib.parse.quote
print('http://%s:%s@%s:%s' % (q(os.environ['PROXY_USER'], safe=''),q(os.environ['PROXY_PASS'], safe=''),os.environ['PROXY_HOST'],os.environ['PROXY_PORT']))
PY
)
unset PROXY_PASS
say '验证 HTTP 代理访问面板'
HTTP_CODE=$(curl -sS --noproxy '' --proxy "$PROXY_URL" --connect-timeout 10 --max-time 20 -o /dev/null -w '%{http_code}' "$PANEL/" ) || die '代理无法连接面板，请先检查代理和 Squid 白名单'
[[ $HTTP_CODE == 200 ]] || die "代理访问面板返回 HTTP $HTTP_CODE（预期 200），请检查账号、白名单及防护规则"
say '代理验证成功'

mkdir -p "$INSTALL_DIR"
if [[ ! -x "$INSTALL_DIR/rel_nodeclient" ]]; then
  die "未找到 $INSTALL_DIR/rel_nodeclient。请先使用 NyanPass 官方安装脚本安装客户端，再重新运行本脚本配置代理与守护。"
fi

if [[ -f "$ENV_FILE" ]]; then cp -p "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d-%H%M%S)"; fi
printf 'export NYA_PROXY=%q\n' "$PROXY_URL" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
# Persist parameters without shell injection: launcher uses shell-escaped literals.
printf '#!/usr/bin/env bash\nset -Eeuo pipefail\ncd /opt/nyanpass\nsource ./env.sh\nexec ./rel_nodeclient -t %q -u %q\n' "$NODE_TOKEN" "$PANEL" > "$LAUNCHER"
chmod 700 "$LAUNCHER"

if command -v supervisorctl >/dev/null && supervisorctl status >/dev/null 2>&1; then
  CONF_DIR=''
  if [[ -d /etc/supervisor/conf.d ]] && grep -Eq '^[[:space:]]*files[[:space:]]*=[[:space:]]*.*conf\.d/\*\.conf' /etc/supervisor/supervisord.conf 2>/dev/null; then
    CONF_DIR=/etc/supervisor/conf.d
  fi
  [[ -n $CONF_DIR ]] || die 'Supervisor 正在运行，但未能确认 conf.d/*.conf 的 include 配置。请人工检查 supervisord.conf。'
  say '配置 Supervisor 守护'
  cat > "$CONF_DIR/nyanpass.conf" <<'CONF'
[program:nyanpass]
directory=/opt/nyanpass
command=/bin/bash /opt/nyanpass/run.sh
user=root
autostart=true
autorestart=true
startsecs=5
startretries=10
stopsignal=TERM
stopasgroup=true
killasgroup=true
stdout_logfile=/var/log/nyanpass.log
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=3
redirect_stderr=true
environment=HOME="/root"
CONF
  supervisorctl reread
  supervisorctl update
  supervisorctl restart nyanpass >/dev/null 2>&1 || supervisorctl start nyanpass || true
  sleep 7
  supervisorctl status nyanpass
elif command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
  say '配置 systemd 守护'
  cat > /etc/systemd/system/nyanpass.service <<'CONF'
[Unit]
Description=NyanPass relay node
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/nyanpass
ExecStart=/bin/bash /opt/nyanpass/run.sh
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
CONF
  systemctl daemon-reload
  systemctl enable --now nyanpass
  systemctl restart nyanpass
  sleep 7
  systemctl --no-pager --full status nyanpass | head -n 18
else
  die '未检测到运行中的 Supervisor 或 systemd；已保存代理和启动脚本，但尚未配置后台守护。'
fi
say '安装完成。日志位置: /var/log/nyanpass.log'
say '若有 bind: address already in use，需另行处理端口冲突。'
