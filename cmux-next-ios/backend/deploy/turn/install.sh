#!/usr/bin/env bash
# Install and start our TURN relay (eturnal) on any Linux box with systemd: one script, idempotent.
# RFD 0088. Run as root on the box (or from cloud-init.yaml). Needs: ETURNAL_SECRET (the Worker's
# TURN_SELF_SECRET) and a TLS certificate. Buying the host, the DNS name and the certificate is not this
# script's job (Leo's list); with RELAY_DOMAIN set and no cert files, it gets one from Let's Encrypt (certbot).
#
#   ETURNAL_SECRET=... RELAY_DOMAIN=relay.cmux.dev ./install.sh
#
# Optional: RELAY_PUBLIC_IPV4 (default: asked of the box's default route), TLS_CERT/TLS_KEY (default:
# /etc/eturnal/tls/fullchain.pem, privkey.pem), ETURNAL_VERSION, ETURNAL_ARCH (x64|arm64).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${ETURNAL_SECRET:?set ETURNAL_SECRET (the same value as TURN_SELF_SECRET)}"
VERSION="${ETURNAL_VERSION:-1.12.3}"
ARCH="${ETURNAL_ARCH:-$(case "$(uname -m)" in aarch64|arm64) echo arm64 ;; *) echo x64 ;; esac)}"
PREFIX=/opt/eturnal
ETC=/etc/eturnal
TLS_CERT="${TLS_CERT:-$ETC/tls/fullchain.pem}"
TLS_KEY="${TLS_KEY:-$ETC/tls/privkey.pem}"
[[ $EUID -eq 0 ]] || { echo "install.sh: run as root" >&2; exit 1; }
case "$ETURNAL_SECRET" in *[!A-Za-z0-9_.=+/-]*) echo "install.sh: ETURNAL_SECRET: letters, digits and _.=+/- only (it goes into YAML)" >&2; exit 1 ;; esac

RELAY_PUBLIC_IPV4="${RELAY_PUBLIC_IPV4:-$(curl -fsS -4 --max-time 10 https://api.ipify.org 2>/dev/null || true)}"
[[ -n "$RELAY_PUBLIC_IPV4" ]] || { echo "install.sh: set RELAY_PUBLIC_IPV4 (could not discover it)" >&2; exit 1; }

id eturnal >/dev/null 2>&1 || useradd --system --home-dir "$PREFIX" --shell /usr/sbin/nologin eturnal
if [[ ! -x "$PREFIX/bin/eturnal" || "$(cat "$PREFIX/.version" 2>/dev/null)" != "$VERSION-$ARCH" ]]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://eturnal.net/download/linux/eturnal-$VERSION-linux-glibc-$ARCH.tar.gz" -o "$tmp/e.tgz"
  rm -rf "$PREFIX"; mkdir -p "$PREFIX"; tar -xzf "$tmp/e.tgz" -C "$PREFIX" --strip-components=1
  echo "$VERSION-$ARCH" > "$PREFIX/.version"
fi

mkdir -p "$ETC/tls" /var/log/eturnal
if [[ ! -s "$TLS_CERT" || ! -s "$TLS_KEY" ]]; then
  : "${RELAY_DOMAIN:?no certificate at $TLS_CERT: set RELAY_DOMAIN (a certbot certificate) or TLS_CERT and TLS_KEY}"
  command -v certbot >/dev/null || { apt-get update -qq && apt-get install -y -qq certbot; }
  certbot certonly --standalone -d "$RELAY_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
  ln -sf "/etc/letsencrypt/live/$RELAY_DOMAIN/fullchain.pem" "$ETC/tls/fullchain.pem"
  ln -sf "/etc/letsencrypt/live/$RELAY_DOMAIN/privkey.pem" "$ETC/tls/privkey.pem"
  TLS_CERT="$ETC/tls/fullchain.pem"; TLS_KEY="$ETC/tls/privkey.pem"
fi

sed -e "s|@ETURNAL_SECRET@|$ETURNAL_SECRET|" -e "s|@RELAY_PUBLIC_IPV4@|$RELAY_PUBLIC_IPV4|" \
    -e "s|@TLS_CERT@|$TLS_CERT|" -e "s|@TLS_KEY@|$TLS_KEY|" "$here/eturnal.yml" > "$ETC/eturnal.yml"
chown -R eturnal:eturnal /var/log/eturnal
chown root:eturnal "$ETC/eturnal.yml"; chmod 640 "$ETC/eturnal.yml"

cat > /etc/systemd/system/eturnal.service <<U
[Unit]
Description=eturnal TURN relay (cmux RFD 0088)
After=network-online.target
Wants=network-online.target

[Service]
User=eturnal
Environment=ETURNAL_ETC_DIR=$ETC HOME=$PREFIX
ExecStart=$PREFIX/bin/eturnal foreground
# TLS on 443 needs the low port without root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=65536
Restart=always
RestartSec=2
ProtectSystem=full
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
U
systemctl daemon-reload
systemctl enable eturnal >/dev/null
systemctl restart eturnal
sleep 3
systemctl is-active --quiet eturnal || { journalctl -u eturnal -n 30 --no-pager >&2; exit 1; }
echo "eturnal $VERSION is up on $RELAY_PUBLIC_IPV4: udp+tcp 3478, udp+tls 443."
echo "Open udp+tcp 3478, udp+tcp 443, udp 49152-65535 in the firewall. Then set the Worker's secrets:"
echo "  TURN_SELF_SECRET=<the same secret>  TURN_SELF_URLS=turn:${RELAY_DOMAIN:-$RELAY_PUBLIC_IPV4}:3478?transport=udp,turn:${RELAY_DOMAIN:-$RELAY_PUBLIC_IPV4}:3478?transport=tcp,turn:${RELAY_DOMAIN:-$RELAY_PUBLIC_IPV4}:443?transport=udp,turns:${RELAY_DOMAIN:-$RELAY_PUBLIC_IPV4}:443?transport=tcp"
