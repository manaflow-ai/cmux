#!/usr/bin/env bash
# install.sh restarts each LaunchAgent only once launchd has unloaded the old one: `launchctl
# bootout` returns before the service is gone, and a bootstrap then fails with "5: Input/output
# error" (cmux-lawrence 2026-10-08: the daemon stayed down and the acpmux and host agents were
# not restarted). Fake launchctl: a service stays loaded for two `print` calls after its bootout,
# and bootstrap fails while it is loaded.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" STATE="$tmp/state"
mkdir -p "$HOME" "$tmp/bin" "$STATE"
for b in optchat-chief cmux-tui cmux acpmux claude; do printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$b"; chmod 755 "$tmp/bin/$b"; done
# `cloud status` says paired, so the host agent starts too.
printf '#!/bin/sh\n[ "$1 $2" = "cloud status" ] && echo "token ok"\nexit 0\n' > "$tmp/bin/optchat-chief"
cat > "$tmp/bin/launchctl" <<'SH'
#!/usr/bin/env bash
label="${2##*/}"
case "$1" in
  print) [[ "$2" == gui/* && "$2" != */* ]] && exit 0
         n="$(cat "$STATE/$label" 2>/dev/null || echo 0)"
         if ((n > 0)); then echo $((n - 1)) > "$STATE/$label"; exit 0; fi
         exit 113 ;;
  bootout) echo 2 > "$STATE/$label"; exit 0 ;;
  bootstrap) label="$(basename "$3" .plist)"
             n="$(cat "$STATE/$label" 2>/dev/null || echo 0)"
             if ((n > 0)); then echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi
             echo "booted $label" >> "$STATE/booted"; exit 0 ;;
esac
SH
chmod 755 "$tmp/bin/launchctl"
PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin" "$here/install.sh" --optchat-chief "$tmp/bin/optchat-chief" \
  --cmux-tui "$tmp/bin/cmux-tui" --cmux "$tmp/bin/cmux" --acpmux "$tmp/bin/acpmux" > "$tmp/out.log" 2>&1 \
  || { echo "FAIL: install.sh failed"; cat "$tmp/out.log"; exit 1; }
for a in daemon acpmux host; do
  grep -q "^booted ai.manaflow.chief-brain.$a$" "$STATE/booted" || { echo "FAIL: $a not booted"; cat "$tmp/out.log"; exit 1; }
done
echo "install-boot.test.sh: ok"
