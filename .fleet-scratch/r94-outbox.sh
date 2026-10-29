# #27294 head only: the Chief outbox demo pass (sourced by the r94 hook after the captures).
# axe sees only the default simulator set, so this pass runs on its own iPhone there, deleted by UDID.
ob="$out/screens/outbox"
mkdir -p "$ob"
axe_bin=/Users/ec2-user/.local/bin/axe
[[ -x "$axe_bin" ]] || axe_bin="$(command -v axe 2>/dev/null || true)"
ob_udid="$(xcrun simctl create "fleet-r94-outbox-${CMUX_CI_STEP_KEY:-local}" "$device_type" "$runtime")"
ob_cleanup() { xcrun simctl shutdown "$ob_udid" >/dev/null 2>&1 || true; xcrun simctl delete "$ob_udid" >/dev/null 2>&1 || true; }
xcrun simctl boot "$ob_udid"
xcrun simctl bootstatus "$ob_udid" -b >/dev/null
xcrun simctl install "$ob_udid" "$app"
ob_launch() {
  xcrun simctl terminate "$ob_udid" "$bundle_id" >/dev/null 2>&1 || true
  SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch "$ob_udid" "$bundle_id" -cmuxMobile.setupComplete YES \
    -cmux-mobile-demo chief-open -cmux-mobile-chief-outbox-demo >/dev/null
}
ob_shot() { xcrun simctl io "$ob_udid" screenshot "$ob/$1.png" >/dev/null; note "- outbox: screens/outbox/$1.png"; }
ob_tree() { [[ -n "$axe_bin" ]] && "$axe_bin" describe-ui --udid "$ob_udid" > "$ob/$1.json" 2>/dev/null || true; }
ob_alert() {  # prints the number of alert nodes in a describe-ui JSON
  python3 -c '
import json, sys
n = 0
def walk(x):
    global n
    t = " ".join(str(x.get(k, "")) for k in ("type", "role", "AXRole", "role_description"))
    if "alert" in t.lower(): n += 1
    for c in x.get("children") or []: walk(c)
try:
    for x in json.load(open(sys.argv[1])): walk(x)
except Exception:
    n = -1
print(n)' "$1"
}
if [[ -z "$axe_bin" ]]; then
  note "- outbox: no axe on this worker; only plain screenshots"
fi
for look in light dark; do
  xcrun simctl ui "$ob_udid" appearance "$look" >/dev/null 2>&1 || true
  xcrun simctl ui "$ob_udid" content_size large >/dev/null 2>&1 || true
  ob_launch
  sleep 2; ob_tree "open-$look-2s"; sleep 4
  ob_tree "open-$look"
  note "- outbox alert-on-open ($look): $(ob_alert "$ob/open-$look-2s.json") at 2 s, $(ob_alert "$ob/open-$look.json") at 6 s (alert nodes; -1 = no tree)"
  ob_shot "portrait-$look"
  if [[ -n "$axe_bin" ]]; then
    "$axe_bin" gesture scroll-up --udid "$ob_udid" >/dev/null 2>&1 || true; sleep 1.5; ob_shot "scrolled-$look"
    "$axe_bin" gesture scroll-up --udid "$ob_udid" >/dev/null 2>&1 || true; sleep 1.5; ob_shot "scrolled2-$look"; ob_tree "scrolled-$look"
  fi
  xcrun simctl ui "$ob_udid" content_size accessibility-extra-large >/dev/null 2>&1 || true
  ob_launch; sleep 6; ob_shot "large-text-$look"; ob_tree "large-text-$look"
  xcrun simctl ui "$ob_udid" content_size large >/dev/null 2>&1 || true
done
# Delete All (light): find it, tap, then show what is left.
xcrun simctl ui "$ob_udid" appearance light >/dev/null 2>&1 || true
ob_launch; sleep 6
if [[ -n "$axe_bin" ]]; then
  for _ in 1 2 3 4; do
    if "$axe_bin" tap --label "Delete All" --udid "$ob_udid" >/dev/null 2>&1; then da=tapped; break; fi
    da=not-found; "$axe_bin" gesture scroll-up --udid "$ob_udid" >/dev/null 2>&1 || true; sleep 1
  done
  sleep 1.5; ob_shot "after-delete-all"; ob_tree "after-delete-all"
  note "- outbox Delete All: $da; alert nodes after: $(ob_alert "$ob/after-delete-all.json")"
fi
note "- outbox landscape: not captured (neither simctl nor axe can rotate a headless simulator)"
ob_cleanup
