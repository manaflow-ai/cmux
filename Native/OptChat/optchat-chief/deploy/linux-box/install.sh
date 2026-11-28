#!/usr/bin/env bash
# Installs a Chief on a shared Linux box: one dedicated system user, one systemd slice that
# caps CPU and memory for the Chief and every agent it starts, and three hardened units
# (chief-box-{daemon,acpmux,host}). Multiplayer Chief, cmuxterm-hq
# plans/multiplayer-chief/DESIGN.md sections 3, 5 and 11; README.md beside this file.
#
# usage (as root):
#   install.sh --optchat-chief PATH --cmux-tui PATH --acpmux PATH --owner user_ID
#              [--cmux PATH] [--prefix /srv/chief] [--user chief]
#              [--cpu-quota 400%] [--memory-max 16G] [--tasks-max 4096]
#              [--claude-base-url URL] [--harness H]
#              [--unit-dir /etc/systemd/system] [--bin-dir /usr/local/bin]
#              [--no-system] [--no-start]
#
# --owner is the Chief owner's cmux account id (user_...). The `chief-box` command reads it
#   for `rights` and `audit`, so the owner's own lines are told apart from teammates'.
# --cmux is the Rust `cmux` CLI from the same build; without it cmux-tui serves as `cmux`
#   (the Cloud Chief VM does the same).
# --claude-base-url gives acpmux a Claude route that signs in by URL (the team subrouter).
#   Otherwise put the model login in PREFIX/model.env (0600, never in a unit file), for
#   example ANTHROPIC_API_KEY=..., and declare it with `chief-box rights auth api-key`.
# --no-system writes the files only: no user, no chown, no systemctl (tests, image builds).
#
# Layout: PREFIX (root:USER 0750) holds root-owned bin/, chief-box.env and model.env, and the
# user's own home/ (HOME: .local, .claude), ws/ (the agents' work dir) and brain/ (state).
# Root never writes inside the user's directories, and refuses any path through a symlink.
# --optchat-chief must have `rights` and `audit` (cmux#33003); an older build is refused.
#
# Safe to run again: it keeps the user, the memory (PREFIX/brain/mux), the pairing
# (PREFIX/brain/cloud/install.json), rights.json, the audit log and model.env.
# The host unit starts only once PREFIX/brain/cloud/install.json is paired and names a chief:
#   chief-box pair --api-base https://<api origin>   (approve the code in the cmux app)
#   chief-box start
set -euo pipefail

PREFIX=/srv/chief U=chief CPU=400% MEM=16G TASKS=4096
CHIEF="" TUI="" CLI="" ACPMUX="" OWNER="" HARNESS="" CLAUDE_URL=""
UNIT_DIR=/etc/systemd/system BIN_DIR=/usr/local/bin SYSTEM=1 START=1
while (($#)); do
  case "$1" in
    --optchat-chief) CHIEF="$2"; shift 2 ;;
    --cmux-tui) TUI="$2"; shift 2 ;;
    --cmux) CLI="$2"; shift 2 ;;
    --acpmux) ACPMUX="$2"; shift 2 ;;
    --owner) OWNER="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --user) U="$2"; shift 2 ;;
    --cpu-quota) CPU="$2"; shift 2 ;;
    --memory-max) MEM="$2"; shift 2 ;;
    --tasks-max) TASKS="$2"; shift 2 ;;
    --harness) HARNESS="$2"; shift 2 ;;
    --claude-base-url) CLAUDE_URL="$2"; shift 2 ;;
    --unit-dir) UNIT_DIR="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; shift 2 ;;
    --no-system) SYSTEM=0; START=0; shift ;;
    --no-start) START=0; shift ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
die() { echo "install.sh: $*" >&2; exit 2; }

# Everything is checked before anything is written.
for b in "$CHIEF" "$TUI" "$ACPMUX"; do [[ -x "$b" ]] || die "not an executable: '$b'"; done
[[ -z "$CLI" || -x "$CLI" ]] || die "not an executable: '$CLI'"
[[ "$OWNER" =~ ^user_[A-Za-z0-9_-]+$ ]] || die "--owner must be the owner's cmux account id, user_... (got '$OWNER')"
[[ "$U" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$U" != root ]] || die "--user must be a plain system user name, not root (got '$U')"
[[ "$PREFIX" =~ ^/[A-Za-z0-9._/-]*$ ]] || die "--prefix must be an absolute path without spaces (got '$PREFIX')"
[[ "$PREFIX" == / ]] || PREFIX="${PREFIX%/}"
case "$PREFIX" in /|/usr|/usr/*|/etc|/etc/*|/bin|/sbin|/lib*|/boot*|/proc*|/sys*|/dev*|/root|/root/*|/home|/home/*) die "--prefix '$PREFIX' is a system or home directory (the units hide /home)" ;; esac
case "$PREFIX/" in */./*|*/../*|*//*) die "--prefix must be a plain absolute path, without . or .. components or //" ;; esac
[[ "$CPU" =~ ^[1-9][0-9]*%$ ]] || die "--cpu-quota must be a percent like 400% (got '$CPU')"
[[ "$MEM" =~ ^[1-9][0-9]*[KMGT]$ ]] || die "--memory-max must be like 16G (got '$MEM')"
[[ "$TASKS" =~ ^[1-9][0-9]*$ ]] || die "--tasks-max must be a number (got '$TASKS')"
[[ -z "$HARNESS" || "$HARNESS" =~ ^[A-Za-z0-9._-]+$ ]] || die "--harness must be a preset name (got '$HARNESS')"
if [[ -n "$CLAUDE_URL" ]]; then
  url_re='^https?://[^][:space:]&<>"'"'"'[]+$'
  [[ "$CLAUDE_URL" =~ $url_re ]] || die "--claude-base-url must be an http(s) URL without spaces, quotes, brackets or & < > (got '$CLAUDE_URL')"
  [[ "$HARNESS" != claude-sr ]] || die "--claude-base-url and --harness claude-sr both set the Claude route; give one"
fi
if ((SYSTEM)); then
  [[ "$(id -u)" == 0 ]] || die "run as root (it adds the user and the units), or pass --no-system"
  command -v systemctl >/dev/null || die "systemd is required"
fi

B="$PREFIX/brain"
# Root-owned: the binaries, the settings and the model login. The Chief's user can read and
# run them but never replace them, so a rerun as root never writes where the Chief points it.
BIN="$PREFIX/bin"
# Chief-owned: its home (.local, .claude), the agents' work dir, and the brain's state.
CH="$PREFIX/home"
SOCK="$B/daemon/cmux.sock"
P=chief-box

# No path root writes through may be a symlink, in any component.
nolink() {
  local p="" part rest="${1#/}"
  while [[ -n "$rest" ]]; do
    part="${rest%%/*}"; [[ "$rest" == */* ]] && rest="${rest#*/}" || rest=""
    p="$p/$part"
    [[ ! -L "$p" ]] || die "refusing to write through a symlink: $p"
  done
}
for p in "$PREFIX" "$BIN" "$PREFIX/chief-box.env" "$PREFIX/model.env" "$CH" "$PREFIX/ws" "$B" "$UNIT_DIR" "$BIN_DIR" "$BIN_DIR/chief-box" \
  "$UNIT_DIR/chief-box.slice" "$UNIT_DIR/chief-box-daemon.service" "$UNIT_DIR/chief-box-acpmux.service" \
  "$UNIT_DIR/chief-box-host.service"; do nolink "$p"; done
for n in optchat-chief cmux-tui acpmux cmux; do nolink "$BIN/$n"; done
# A kept model.env must be a plain file the Chief cannot write: owned by root (by the
# installing user with --no-system), mode 0600. Anything else is refused, never repaired.
me="$(id -u)"
if [[ -e "$PREFIX/model.env" || -L "$PREFIX/model.env" ]]; then
  [[ -f "$PREFIX/model.env" && ! -L "$PREFIX/model.env" ]] || die "$PREFIX/model.env is not a regular file; move it aside and run again"
  meta="$(stat -c '%u %a' "$PREFIX/model.env" 2>/dev/null || stat -f '%u %Lp' "$PREFIX/model.env")"
  [[ "$meta" == "$me 600" ]] || die "$PREFIX/model.env must be owned by uid $me with mode 600 (it is: uid/mode $meta); check its contents, fix it and run again"
fi

# The optchat-chief must have the rights table and the audit log (cmux#33003): `audit head`
# on an empty home answers "0 <genesis hash>"; an older build prints its usage and exits 2.
probe="$(mktemp -d)"
if ! out="$(env -i PATH=/usr/bin:/bin HOME="$probe" MUX_HOME="$probe/mux" "$CHIEF" audit head --mux-home "$probe/mux" 2>&1 </dev/null)" \
  || ! [[ "$out" =~ ^0\ [0-9a-f]+$ ]]; then
  rm -rf "$probe"
  die "this optchat-chief has no rights table or audit log (\`optchat-chief audit head\` answered '${out:0:120}'); build it from a tree with cmux#33003"
fi
rm -rf "$probe"

umask 022
mkdir -p "$UNIT_DIR" "$BIN_DIR"
if ((SYSTEM)); then
  # A system user whose home is PREFIX/home: no password, no sudo (bash is kept so
  # `chief-box` can run commands as it).
  id "$U" >/dev/null 2>&1 || useradd --system --home-dir "$CH" --no-create-home --shell /bin/bash --user-group "$U"
  [[ "$(getent passwd "$U" | cut -d: -f6)" == "$CH" ]] || usermod --home "$CH" "$U"
fi
[[ -d "$PREFIX" ]] || install -d -m 0750 "$PREFIX"
[[ -d "$BIN" ]] || install -d -m 0755 "$BIN"
if ((SYSTEM)); then chown root:"$U" "$PREFIX"; chmod 0750 "$PREFIX"; chown root:root "$BIN"; chmod 0755 "$BIN"; fi
for pair in "optchat-chief:$CHIEF" "cmux-tui:$TUI" "acpmux:$ACPMUX" "cmux:${CLI:-$TUI}"; do
  name="${pair%%:*}" src="${pair#*:}"
  rm -f "$BIN/$name"
  install -m 0755 "$src" "$BIN/$name"
done
# The non-secret settings the units read. Written as a fresh root-owned file and renamed over
# the old one, so a file the Chief once owned is replaced, never reused.
put() { # dest mode: stdin to a new file beside dest (a root-owned dir), then rename over it.
  # The rename replaces a symlink or another owner's file; it never writes through one.
  local t; t="$(mktemp "$(dirname "$1")/.chief-box.XXXXXX")"
  cat > "$t"; chmod "$2" "$t"
  if ((SYSTEM)); then chown root:root "$t"; fi
  mv -f "$t" "$1"
}
put "$PREFIX/chief-box.env" 0644 <<EOF
CHIEF_BOX_USER=$U
CHIEF_BOX_PREFIX=$PREFIX
CHIEF_BOX_HOME=$CH
MUX_HOME=$B/mux
OPTCHAT_CHIEF_OWNER=$OWNER
EOF
# systemd reads it as root; the Chief's processes get its values, never the file.
[[ -e "$PREFIX/model.env" ]] || put "$PREFIX/model.env" 0600 </dev/null

# The Chief's own directories sit directly under the root-owned PREFIX, so the Chief cannot
# swap them; anything inside them is made by the Chief's user, never by root.
as_user() { if ((SYSTEM)); then runuser -u "$U" -- "$@"; else "$@"; fi; }
for d in "$CH" "$PREFIX/ws" "$B"; do
  [[ -d "$d" ]] || install -d -m 0700 "$d"
  if ((SYSTEM)); then chown -h "$U:$U" "$d"; fi
done
as_user mkdir -p -m 0700 "$CH/.local/bin" "$CH/.claude" "$B/mux" "$B/acpmux" "$B/daemon" "$B/cloud" "$B/logs" "$B/tmp"

# Every Chief process and every agent acpmux starts lives in this slice, so the caps hold
# for the whole Chief together and a runaway agent cannot starve the box's other work.
put "$UNIT_DIR/$P.slice" 0644 <<EOF
[Unit]
Description=Chief on a shared Linux box (all its processes and agents)

[Slice]
CPUAccounting=yes
CPUQuota=$CPU
MemoryAccounting=yes
MemoryMax=$MEM
TasksMax=$TASKS
EOF

unit() { # name description exec [Key=Value lines...]
  local n=$1 d=$2 x=$3; shift 3
  {
    echo "[Unit]"
    echo "Description=$d"
    echo "After=network-online.target${UNIT_AFTER:+ $UNIT_AFTER}"
    echo "Wants=network-online.target${UNIT_AFTER:+ $UNIT_AFTER}"
    [[ -z "${UNIT_COND:-}" ]] || echo "ConditionPathExists=$UNIT_COND"
    if [[ "$n" != "$P-daemon" ]]; then
      echo "Requires=$P-daemon.service"
      echo "PartOf=$P-daemon.service"
      echo "JoinsNamespaceOf=$P-daemon.service"
    fi
    echo
    echo "[Service]"
    echo "User=$U"
    echo "Group=$U"
    echo "Slice=$P.slice"
    echo "WorkingDirectory=$PREFIX/ws"
    echo "Environment=HOME=$CH"
    echo "Environment=PATH=$BIN:$CH/.local/bin:/usr/local/bin:/usr/bin:/bin"
    echo "EnvironmentFile=$PREFIX/chief-box.env"
    for line in "$@"; do echo "$line"; done
    echo "ExecStart=$x"
    echo "Restart=always"
    echo "RestartSec=3"
    echo "UMask=0077"
    # Hardening: the Chief and its agents write only under PREFIX.
    echo "NoNewPrivileges=yes"
    echo "ProtectSystem=strict"
    echo "ProtectHome=yes"
    echo "ReadWritePaths=$PREFIX"
    # One private /tmp for the three units together: the host makes the compactor's dirs
    # and acpmux's socket aliases (/tmp/acpmux-UID) that acpmux must see. The daemon owns
    # it; the others join it and stop and restart with it.
    echo "PrivateTmp=yes"
    echo "Environment=TMPDIR=$B/tmp"
    echo "PrivateDevices=yes"
    echo "ProtectKernelTunables=yes"
    echo "ProtectKernelModules=yes"
    echo "ProtectKernelLogs=yes"
    echo "ProtectControlGroups=yes"
    echo "ProtectClock=yes"
    echo "ProtectHostname=yes"
    echo "RestrictSUIDSGID=yes"
    echo "RestrictRealtime=yes"
    echo "LockPersonality=yes"
    echo "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK"
    echo "CapabilityBoundingSet="
    echo "AmbientCapabilities="
    echo
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } | put "$UNIT_DIR/$n.service" 0644
  echo "wrote $UNIT_DIR/$n.service"
}

unit "$P-daemon" "Chief box cmux-tui daemon (the Chief's own; never shared)" \
  "$BIN/cmux-tui --headless --socket $SOCK" \
  "Environment=ACPMUX_HOME=$B/acpmux" "Environment=CMUX_TUI_CHIEF_TOOLS_SOCKET=$B/mux/optchat/tools.sock"

acpmux_env=("Environment=ACPMUX_HOME=$B/acpmux" "Environment=ACPMUX_CHIEF_MUX_HOME=$B/mux"
  "Environment=CMUX_TUI_SOCKET=$SOCK" "Environment=CMUX_MUX_SOCKET=$SOCK"
  "Environment=CMUX_CHIEF_OWNER_SOCKET=$SOCK" "Environment=CMUX_BUNDLED_CLI_PATH=$BIN/cmux"
  "EnvironmentFile=-$PREFIX/model.env")
if [[ -n "$CLAUDE_URL" ]]; then
  acpmux_env+=("Environment=ANTHROPIC_BASE_URL=$CLAUDE_URL" "Environment=ANTHROPIC_AUTH_TOKEN=unused-route-signs-in-by-url")
  echo "acpmux Claude route: $CLAUDE_URL"
else
  echo "acpmux Claude route: none given; the model login comes from $PREFIX/model.env"
fi
UNIT_AFTER="$P-daemon.service" unit "$P-acpmux" "Chief box acpmux (the Chief's agents)" \
  "$BIN/acpmux daemon run" "${acpmux_env[@]}"

host_env=("Environment=ACPMUX_HOME=$B/acpmux" "Environment=ACPMUX_SOCKET=$B/acpmux/acpmux.sock"
  "Environment=ACPMUX_BIN=$BIN/acpmux" "Environment=CMUX_DAEMON_SOCKET=$SOCK"
  "Environment=OPTCHAT_ACPMUX_SUPERVISED=1" "EnvironmentFile=-$PREFIX/model.env")
[[ -z "$HARNESS" ]] || host_env+=("Environment=MUX_HARNESS=$HARNESS")
UNIT_AFTER="$P-daemon.service $P-acpmux.service" UNIT_COND="$B/cloud/install.json" \
  unit "$P-host" "Chief box brain host (cloud conversation source)" \
  "$BIN/optchat-chief host --conversation-source cloud --cloud-install $B/cloud/install.json --daemon-socket $SOCK --mux-home $B/mux" \
  "${host_env[@]}"

# `chief-box`: the owner's commands on the box, run as the Chief's user.
put "$BIN_DIR/chief-box" 0755 <<EOF
#!/usr/bin/env bash
# The Chief on this box (deploy/linux-box/README.md). Written by install.sh.
set -euo pipefail
# The settings are fixed here at install time, never read from a file at run time.
CHIEF_BOX_USER=$U CHIEF_BOX_HOME=$CH MUX_HOME=$B/mux OPTCHAT_CHIEF_OWNER=$OWNER
B=$B BIN=$BIN
as_chief() {
  if [[ "\$(id -un)" == "\$CHIEF_BOX_USER" ]]; then env HOME="\$CHIEF_BOX_HOME" MUX_HOME="\$MUX_HOME" OPTCHAT_CHIEF_OWNER="\$OPTCHAT_CHIEF_OWNER" "\$@"
  else runuser -u "\$CHIEF_BOX_USER" -- env HOME="\$CHIEF_BOX_HOME" MUX_HOME="\$MUX_HOME" OPTCHAT_CHIEF_OWNER="\$OPTCHAT_CHIEF_OWNER" "\$@"; fi
}
case "\${1:-}" in
  pair) shift; as_chief "\$BIN/optchat-chief" cloud pair --install "\$B/cloud/install.json" "\$@" ;;
  status) as_chief "\$BIN/optchat-chief" cloud status --install "\$B/cloud/install.json"
          systemctl --no-pager status $P.slice $P-daemon $P-acpmux $P-host | sed -n '1,40p' || true ;;
  start) as_chief "\$BIN/optchat-chief" cloud status --install "\$B/cloud/install.json" | grep -q '^token ok' \\
           || { echo "chief-box: not paired, or no chief placed on this box: run chief-box pair --api-base URL" >&2; exit 1; }
         # model.env or the binaries may have changed: acpmux and the host read them at start.
         systemctl restart $P-acpmux; systemctl enable $P-host; systemctl restart $P-host ;;
  reload-model) systemctl restart $P-acpmux $P-host ;;
  stop) systemctl stop $P-host $P-acpmux ;;  # acpmux too: no agent keeps running or spending
  rights|audit|usage) as_chief "\$BIN/optchat-chief" "\$@" ;;
  logs) journalctl --no-pager -n "\${2:-200}" -u $P-host -u $P-acpmux -u $P-daemon ;;
  *) echo "usage: chief-box pair --api-base URL | status | start | stop | reload-model | rights ... | audit [verify|head] | usage | logs [N]" >&2; exit 2 ;;
esac
EOF
echo "wrote $BIN_DIR/chief-box"

((SYSTEM)) || { echo "files only (--no-system)"; exit 0; }
systemctl daemon-reload
systemctl enable $P-daemon $P-acpmux >/dev/null 2>&1
((START)) || { echo "not started (--no-start)"; exit 0; }
systemctl restart $P-daemon $P-acpmux
if runuser -u "$U" -- env HOME="$CH" "$BIN/optchat-chief" cloud status --install "$B/cloud/install.json" 2>/dev/null | grep -q '^token ok'; then
  systemctl enable $P-host >/dev/null 2>&1; systemctl restart $P-host; echo "started $P-host"
else
  echo "host NOT started: $B/cloud/install.json is not paired or names no chief"
  echo "  run: chief-box pair --api-base https://<api origin>, approve the code in the cmux app"
  echo "  (Server > Add Server…, then place the Chief on this server), then: chief-box start"
fi
