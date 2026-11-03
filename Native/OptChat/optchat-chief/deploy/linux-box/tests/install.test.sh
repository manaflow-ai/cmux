#!/usr/bin/env bash
# install.sh --no-system writes the Chief box's slice, three hardened units and `chief-box`:
# the caps sit on one slice every unit joins, every unit runs as the Chief's own user and
# writes only under the prefix, the host waits for a paired install, the model login stays
# out of the unit files, and bad input is refused before anything is written.
# Runs anywhere (no root, no systemd); with systemd-analyze present the units are verified too.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
for b in optchat-chief cmux-tui acpmux cmux; do printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$b"; chmod 755 "$tmp/bin/$b"; done
pre="$tmp/srv/chief" units="$tmp/units" bins="$tmp/usrbin"
base=(--optchat-chief "$tmp/bin/optchat-chief" --cmux-tui "$tmp/bin/cmux-tui" --acpmux "$tmp/bin/acpmux"
  --owner user_ann --prefix "$pre" --unit-dir "$units" --bin-dir "$bins" --no-system)
fail() { echo "FAIL: $*"; exit 1; }
run() { "$here/install.sh" "$@" > "$tmp/out.log" 2>&1 || { cat "$tmp/out.log"; fail "install.sh $*"; }; }
has() { grep -qxF -- "$2" "$units/$1" || fail "$1 lacks '$2'"; }
lacks() { if grep -q -- "$2" "$units/$1"; then fail "$1 has '$2'"; fi; }

run "${base[@]}"
b="$pre/brain" sock="$pre/brain/daemon/cmux.sock"
has chief-box.slice "CPUQuota=400%"
has chief-box.slice "MemoryMax=16G"
has chief-box.slice "TasksMax=4096"
for u in daemon acpmux host; do
  f="chief-box-$u.service"
  [[ -f "$units/$f" ]] || fail "no $f"
  for line in "User=chief" "Group=chief" "Slice=chief-box.slice" "NoNewPrivileges=yes" "ProtectSystem=strict" \
    "ProtectHome=yes" "ReadWritePaths=$pre" "PrivateTmp=yes" "CapabilityBoundingSet=" "UMask=0077" \
    "Environment=HOME=$pre" "EnvironmentFile=$pre/chief-box.env" "WorkingDirectory=$pre/ws"; do has "$f" "$line"; done
  lacks "$f" "ANTHROPIC_API_KEY"
done
has chief-box-daemon.service "ExecStart=$b/bin/cmux-tui --headless --socket $sock"
has chief-box-daemon.service "Environment=ACPMUX_HOME=$b/acpmux"
has chief-box-acpmux.service "ExecStart=$b/bin/acpmux daemon run"
has chief-box-acpmux.service "Environment=ACPMUX_CHIEF_MUX_HOME=$b/mux"
has chief-box-acpmux.service "Environment=CMUX_CHIEF_OWNER_SOCKET=$sock"
has chief-box-acpmux.service "EnvironmentFile=-$pre/model.env"
lacks chief-box-acpmux.service "ANTHROPIC_BASE_URL"
has chief-box-host.service "ExecStart=$b/bin/optchat-chief host --conversation-source cloud --cloud-install $b/cloud/install.json --daemon-socket $sock --mux-home $b/mux"
has chief-box-host.service "ConditionPathExists=$b/cloud/install.json"
has chief-box-host.service "Environment=OPTCHAT_ACPMUX_SUPERVISED=1"
lacks chief-box-host.service "MUX_HARNESS"
grep -qxF "OPTCHAT_CHIEF_OWNER=user_ann" "$pre/chief-box.env" || fail "chief-box.env has no owner"
grep -qxF "MUX_HOME=$b/mux" "$pre/chief-box.env" || fail "chief-box.env has no MUX_HOME"
[[ "$(stat -c %a "$pre/model.env" 2>/dev/null || stat -f %Lp "$pre/model.env")" == 600 ]] || fail "model.env is not 0600"
[[ -x "$b/bin/cmux" ]] || fail "no cmux in $b/bin (cmux-tui serves as cmux without --cmux)"
[[ -x "$bins/chief-box" ]] || fail "no chief-box command"
bash -n "$bins/chief-box" || fail "chief-box does not parse"
grep -q 'cloud pair --install "$B/cloud/install.json"' "$bins/chief-box" || fail "chief-box pair does not pair this box's install"

# A rerun keeps the owner's model login, rights and audit; flags change the caps and the route.
echo "ANTHROPIC_API_KEY=sk-test" > "$pre/model.env"
mkdir -p "$b/mux/optchat/audit"; echo '{"version":1}' > "$b/mux/optchat/rights.json"; echo '{}' > "$b/mux/optchat/audit/audit.jsonl"
run "${base[@]}" --cpu-quota 200% --memory-max 8G --harness codex --claude-base-url http://router.test:31415
grep -qxF "ANTHROPIC_API_KEY=sk-test" "$pre/model.env" || fail "a rerun replaced model.env"
[[ -s "$b/mux/optchat/rights.json" && -s "$b/mux/optchat/audit/audit.jsonl" ]] || fail "a rerun lost rights.json or the audit log"
has chief-box.slice "CPUQuota=200%"
has chief-box.slice "MemoryMax=8G"
has chief-box-host.service "Environment=MUX_HARNESS=codex"
has chief-box-acpmux.service "Environment=ANTHROPIC_BASE_URL=http://router.test:31415"
for f in chief-box-daemon.service chief-box-acpmux.service chief-box-host.service; do lacks "$f" "sk-test"; done

# Bad input is refused before anything is written.
cp -R "$units" "$tmp/units.before"
for bad in "--owner ann|--owner must be" "--owner user_x;rm|--owner must be" "--prefix /|system or home" \
  "--prefix /home/chief|system or home" "--prefix /etc/chief|system or home" "--user root|--user must be" \
  "--cpu-quota 4|--cpu-quota must be" "--memory-max lots|--memory-max must be" \
  "--claude-base-url http://r.test/?a=1&b=2|must be an http(s) URL" \
  "--claude-base-url http://r.test --harness claude-sr|both set the Claude route"; do
  args="${bad%%|*}" why="${bad#*|}"
  # shellcheck disable=SC2086
  if "$here/install.sh" "${base[@]}" $args > "$tmp/out.log" 2>&1; then fail "install.sh accepted $args"; fi
  grep -qF -- "$why" "$tmp/out.log" || fail "install.sh refused $args for another reason: $(cat "$tmp/out.log")"
done
diff -r "$tmp/units.before" "$units" >/dev/null || fail "a refused install changed the units"
if "$here/install.sh" --optchat-chief "$tmp/bin/optchat-chief" --cmux-tui "$tmp/bin/cmux-tui" --acpmux "$tmp/bin/acpmux" \
  --owner user_ann --prefix "$pre" --unit-dir "$units" --bin-dir "$bins" > "$tmp/out.log" 2>&1 && [[ "$(id -u)" != 0 ]]; then
  fail "install.sh without --no-system ran as a non-root user"
fi

if command -v systemd-analyze >/dev/null 2>&1; then
  # Verify the unit syntax only (the binaries and user exist on a real box, not here).
  systemd-analyze verify --man=no "$units"/chief-box*.service "$units/chief-box.slice" > "$tmp/verify.log" 2>&1 || true
  if grep -E "Unknown (key|section)|Invalid|Failed to parse" "$tmp/verify.log"; then fail "systemd-analyze rejects a unit"; fi
fi
echo "install.test.sh: ok"
