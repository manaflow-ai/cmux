#!/usr/bin/env bash
# install.sh --no-system writes the Chief box's slice, three hardened units and `chief-box`:
# the caps sit on one slice every unit joins, every unit runs as the Chief's own user and
# writes only under the prefix, the host waits for a paired install, the model login stays
# out of the unit files, and bad input is refused before anything is written.
# Runs anywhere (no root, no systemd); with systemd-analyze present the units are verified too.
set -euo pipefail
# Refuse root before anything runs: as root, a call without --no-system would add or change a
# real `chief` user and write real units. Run it as an unprivileged user.
if [[ "$(id -u)" == 0 ]]; then echo "install.test.sh: refusing to run as root; run it as an unprivileged user" >&2; exit 1; fi
exec 3>&2  # for failures inside redirected installer calls
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
for b in cmux-tui acpmux cmux old-chief; do printf '#!/bin/sh\necho "usage: ..." >&2; exit 2\n' > "$tmp/bin/$b"; chmod 755 "$tmp/bin/$b"; done
# An optchat-chief with the audit log (cmux#33003) answers `audit head` on an empty home.
printf '#!/bin/sh\n[ "$1 $2" = "audit head" ] && { echo "0 0000abcd"; exit 0; }\nexit 0\n' > "$tmp/bin/optchat-chief"; chmod 755 "$tmp/bin/optchat-chief"
pre="$tmp/srv/chief" units="$tmp/units" bins="$tmp/usrbin"
base=(--optchat-chief "$tmp/bin/optchat-chief" --cmux-tui "$tmp/bin/cmux-tui" --acpmux "$tmp/bin/acpmux"
  --owner user_ann --prefix "$pre" --unit-dir "$units" --bin-dir "$bins" --no-system)
fail() { echo "FAIL: $*"; exit 1; }
# Every call goes through inst: --no-system and the temp unit and bin dirs, or the test fails.
inst() {
  local a=" $* "
  [[ "$a" == *" --no-system "* && "$a" == *" --unit-dir $units "* && "$a" == *" --bin-dir $bins "* ]] \
    || { echo "FAIL: the test called install.sh without --no-system and its temp --unit-dir/--bin-dir" >&3; exit 1; }
  "$here/install.sh" "$@"
}
run() { inst "$@" > "$tmp/out.log" 2>&1 || { cat "$tmp/out.log"; fail "install.sh $*"; }; }
has() { grep -qxF -- "$2" "$units/$1" || fail "$1 lacks '$2'"; }
lacks() { if grep -q -- "$2" "$units/$1"; then fail "$1 has '$2'"; fi; }

run "${base[@]}"
b="$pre/brain" sock="$pre/brain/daemon/cmux.sock" bin="$pre/bin" ch="$pre/home"
has chief-box.slice "CPUQuota=400%"
has chief-box.slice "MemoryMax=16G"
has chief-box.slice "TasksMax=4096"
for u in daemon acpmux host; do
  f="chief-box-$u.service"
  [[ -f "$units/$f" ]] || fail "no $f"
  for line in "User=chief" "Group=chief" "Slice=chief-box.slice" "NoNewPrivileges=yes" "ProtectSystem=strict" \
    "ProtectHome=yes" "ReadWritePaths=$pre" "PrivateTmp=yes" "CapabilityBoundingSet=" "UMask=0077" \
    "Environment=HOME=$ch" "EnvironmentFile=$pre/chief-box.env" "WorkingDirectory=$pre/ws"; do has "$f" "$line"; done
  lacks "$f" "ANTHROPIC_API_KEY"
done
for u in acpmux host; do
  for line in "Requires=chief-box-daemon.service" "PartOf=chief-box-daemon.service" "JoinsNamespaceOf=chief-box-daemon.service"; do
    has "chief-box-$u.service" "$line"
  done
done
lacks chief-box-daemon.service "JoinsNamespaceOf"
for u in daemon acpmux host; do has "chief-box-$u.service" "Environment=TMPDIR=$b/tmp"; done
# JoinsNamespaceOf is a [Unit] key: it must come before [Service].
awk '/^\[Service\]/{s=1} /^JoinsNamespaceOf=/{ if (s) exit 1 }' "$units/chief-box-host.service" || fail "JoinsNamespaceOf is not in [Unit]"
has chief-box-daemon.service "ExecStart=$bin/cmux-tui --headless --socket $sock"
has chief-box-daemon.service "Environment=ACPMUX_HOME=$b/acpmux"
has chief-box-acpmux.service "ExecStart=$bin/acpmux daemon run"
has chief-box-acpmux.service "Environment=ACPMUX_CHIEF_MUX_HOME=$b/mux"
has chief-box-acpmux.service "Environment=CMUX_CHIEF_OWNER_SOCKET=$sock"
has chief-box-acpmux.service "EnvironmentFile=-$pre/model.env"
lacks chief-box-acpmux.service "ANTHROPIC_BASE_URL"
has chief-box-host.service "ExecStart=$bin/optchat-chief host --conversation-source cloud --cloud-install $b/cloud/install.json --daemon-socket $sock --mux-home $b/mux"
has chief-box-host.service "ConditionPathExists=$b/cloud/install.json"
has chief-box-host.service "Environment=OPTCHAT_ACPMUX_SUPERVISED=1"
lacks chief-box-host.service "MUX_HARNESS"
grep -qxF "OPTCHAT_CHIEF_OWNER=user_ann" "$pre/chief-box.env" || fail "chief-box.env has no owner"
grep -qxF "MUX_HOME=$b/mux" "$pre/chief-box.env" || fail "chief-box.env has no MUX_HOME"
[[ "$(stat -c %a "$pre/model.env" 2>/dev/null || stat -f %Lp "$pre/model.env")" == 600 ]] || fail "model.env is not 0600"
[[ -x "$bin/cmux" ]] || fail "no cmux in $bin (cmux-tui serves as cmux without --cmux)"
[[ ! -e "$b/bin" ]] || fail "binaries under the Chief-owned brain/"
for d in "$ch/.local/bin" "$ch/.claude" "$b/mux" "$b/acpmux" "$b/daemon" "$b/cloud" "$b/logs" "$pre/ws"; do [[ -d "$d" ]] || fail "no $d"; done
has chief-box-acpmux.service "Environment=PATH=$bin:$ch/.local/bin:/usr/local/bin:/usr/bin:/bin"
grep -qxF "CHIEF_BOX_HOME=$ch" "$pre/chief-box.env" || fail "chief-box.env has no CHIEF_BOX_HOME"
grep -q 'reload-model) systemctl restart chief-box-acpmux chief-box-host' "$bins/chief-box" || fail "no chief-box reload-model"
grep -q 'systemctl restart chief-box-acpmux; systemctl enable chief-box-host' "$bins/chief-box" || fail "chief-box start does not restart acpmux (model.env)"
[[ -x "$bins/chief-box" ]] || fail "no chief-box command"
bash -n "$bins/chief-box" || fail "chief-box does not parse"
grep -q 'cloud pair --install "$B/cloud/install.json"' "$bins/chief-box" || fail "chief-box pair does not pair this box's install"
# chief-box runs as root: it reads no settings file at run time (a Chief-writable file would be root's shell).
if grep -E '^[[:space:]]*(\.|source)[[:space:]]' "$bins/chief-box"; then fail "chief-box sources a file"; fi
grep -qxF "CHIEF_BOX_USER=chief CHIEF_BOX_HOME=$ch MUX_HOME=$b/mux OPTCHAT_CHIEF_OWNER=user_ann" "$bins/chief-box" || fail "chief-box does not carry its settings"
grep -q 'stop) systemctl stop chief-box-host chief-box-acpmux' "$bins/chief-box" || fail "chief-box stop leaves acpmux (agents) running"

# A settings file someone else wrote is replaced by a fresh file, not rewritten in place.
printf 'CHIEF_BOX_USER=$(id)\n' > "$pre/chief-box.env"; chmod 0666 "$pre/chief-box.env"
ino_before="$(ls -i "$pre/chief-box.env" | awk '{print $1}')"
run "${base[@]}"
[[ "$(ls -i "$pre/chief-box.env" | awk '{print $1}')" != "$ino_before" ]] || fail "chief-box.env was rewritten in place"
[[ "$(stat -c %a "$pre/chief-box.env" 2>/dev/null || stat -f %Lp "$pre/chief-box.env")" == 644 ]] || fail "chief-box.env is not 0644"
grep -q 'id)' "$pre/chief-box.env" && fail "chief-box.env kept the injected line"
grep -qxF "CHIEF_BOX_USER=chief" "$pre/chief-box.env" || fail "chief-box.env lost its settings"
[[ -z "$(ls -A "$pre" | grep '^\.chief-box\.')" ]] || fail "temp settings files left in the prefix"

# A kept model.env that is a symlink, or has the wrong mode, is refused.
mv "$pre/model.env" "$tmp/model.env.real"
ln -s "$tmp/model.env.real" "$pre/model.env"
if inst "${base[@]}" > "$tmp/out.log" 2>&1; then fail "install.sh accepted a symlinked model.env"; fi
grep -q -E "model.env is not a regular file|refusing to write through a symlink: .*/model.env" "$tmp/out.log" || fail "symlinked model.env refused for another reason: $(cat "$tmp/out.log")"
rm "$pre/model.env"; mv "$tmp/model.env.real" "$pre/model.env"
chmod 0644 "$pre/model.env"
if inst "${base[@]}" > "$tmp/out.log" 2>&1; then fail "install.sh accepted a 0644 model.env"; fi
grep -q "model.env must be owned by uid" "$tmp/out.log" || fail "0644 model.env refused for another reason: $(cat "$tmp/out.log")"
chmod 0600 "$pre/model.env"

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

# An optchat-chief without the rights table and audit log (before cmux#33003) is refused.
if inst "${base[@]/$tmp\/bin\/optchat-chief/$tmp/bin/old-chief}" > "$tmp/out.log" 2>&1; then fail "install.sh accepted an optchat-chief without audit"; fi
grep -q "no rights table or audit log" "$tmp/out.log" || fail "old optchat-chief refused for another reason: $(cat "$tmp/out.log")"

# Root never writes through a symlink the Chief could plant (brain/ and home/ are the Chief's).
mv "$bin" "$tmp/bin.real"; ln -s "$tmp/elsewhere" "$bin"
if inst "${base[@]}" > "$tmp/out.log" 2>&1; then fail "install.sh wrote through a symlinked bin/"; fi
grep -q "refusing to write through a symlink: $bin" "$tmp/out.log" || fail "symlinked bin/ refused for another reason: $(cat "$tmp/out.log")"
[[ ! -e "$tmp/elsewhere" ]] || fail "install.sh wrote outside the prefix"
rm "$bin"; mv "$tmp/bin.real" "$bin"
ln -s "$tmp/elsewhere" "$tmp/pre-link"
if inst "${base[@]/$pre/$tmp/pre-link}" > "$tmp/out.log" 2>&1; then fail "install.sh accepted a symlinked prefix"; fi
grep -q "refusing to write through a symlink" "$tmp/out.log" || fail "symlinked prefix refused for another reason: $(cat "$tmp/out.log")"

# A unit path that is a symlink (a masked unit, -> /dev/null) is refused and its target untouched.
echo keep > "$tmp/masked"; chmod 0600 "$tmp/masked"
mv "$units/chief-box-acpmux.service" "$tmp/acpmux.unit.real"; ln -s "$tmp/masked" "$units/chief-box-acpmux.service"
if inst "${base[@]}" > "$tmp/out.log" 2>&1; then fail "install.sh wrote over a symlinked unit"; fi
grep -q "refusing to write through a symlink: $units/chief-box-acpmux.service" "$tmp/out.log" || fail "symlinked unit refused for another reason: $(cat "$tmp/out.log")"
[[ "$(cat "$tmp/masked")" == keep && "$(stat -c %a "$tmp/masked" 2>/dev/null || stat -f %Lp "$tmp/masked")" == 600 ]] || fail "install.sh changed a symlinked unit's target"
rm "$units/chief-box-acpmux.service"; mv "$tmp/acpmux.unit.real" "$units/chief-box-acpmux.service"
mv "$units/chief-box.slice" "$tmp/slice.real"; ln -s "$tmp/masked" "$units/chief-box.slice"
if inst "${base[@]}" > "$tmp/out.log" 2>&1; then fail "install.sh wrote over a symlinked slice"; fi
[[ "$(cat "$tmp/masked")" == keep ]] || fail "install.sh wrote through a symlinked slice"
rm "$units/chief-box.slice"; mv "$tmp/slice.real" "$units/chief-box.slice"
# Units are replaced by rename, never rewritten in place.
ino_before="$(ls -i "$units/chief-box-host.service" | awk '{print $1}')"
run "${base[@]}"
[[ "$(ls -i "$units/chief-box-host.service" | awk '{print $1}')" != "$ino_before" ]] || fail "a unit was rewritten in place"
[[ -z "$(ls -A "$units" "$bins" | grep '^\.chief-box\.')" ]] || fail "temp files left beside the units or chief-box"

# Bad input is refused before anything is written.
cp -R "$units" "$tmp/units.before"
for bad in "--owner ann|--owner must be" "--owner user_x;rm|--owner must be" "--prefix /|system or home" \
  "--prefix /home/chief|system or home" "--prefix /etc/chief|system or home" "--prefix /srv/../etc|without . or .." "--prefix /srv/./chief|without . or .." \
  "--prefix /srv//chief|without . or .." "--user root|--user must be" \
  "--cpu-quota 4|--cpu-quota must be" "--memory-max lots|--memory-max must be" \
  "--claude-base-url http://r.test/?a=1&b=2|must be an http(s) URL" \
  "--claude-base-url http://r.test --harness claude-sr|both set the Claude route"; do
  args="${bad%%|*}" why="${bad#*|}"
  # shellcheck disable=SC2086
  if inst "${base[@]}" $args > "$tmp/out.log" 2>&1; then fail "install.sh accepted $args"; fi
  grep -qF -- "$why" "$tmp/out.log" || fail "install.sh refused $args for another reason: $(cat "$tmp/out.log")"
done
diff -r "$tmp/units.before" "$units" >/dev/null || fail "a refused install changed the units"

if command -v systemd-analyze >/dev/null 2>&1; then
  # Verify the unit syntax only (the binaries and user exist on a real box, not here).
  systemd-analyze verify --man=no "$units"/chief-box*.service "$units/chief-box.slice" > "$tmp/verify.log" 2>&1 || true
  if grep -E "Unknown (key|section)|Invalid|Failed to parse" "$tmp/verify.log"; then fail "systemd-analyze rejects a unit"; fi
fi
echo "install.test.sh: ok"
