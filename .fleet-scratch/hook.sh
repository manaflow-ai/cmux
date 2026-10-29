# Scratch hook for #27300 receipts (sourced by the patched cmux-next-ios-sim.sh after the launch shot).
# Captures and the UI test run on simulators in the default device set (axe and xcodebuild see only
# that set); each is created here and deleted by its UDID.
axe=/Users/ec2-user/.local/bin/axe
[[ -x "$axe" ]] || axe="$(command -v axe || true)"
r00_devs=()
r00_cleanup() { for d in "${r00_devs[@]}"; do xcrun simctl shutdown "$d" >/dev/null 2>&1 || true; xcrun simctl delete "$d" >/dev/null 2>&1 || true; done; }

# --- UI test: ComposerKeyboardPinUITests (only when .fleet-scratch/uitest exists) ---
if [[ -f .fleet-scratch/uitest ]]; then
  t0=$SECONDS
  ui_udid="$(xcrun simctl create "r00-uitest-${CMUX_CI_STEP_KEY:-local}" "$device_type" "$runtime")"
  r00_devs+=("$ui_udid")
  set +e
  xcodebuild test -project cmux-next-ios/CmuxMobileApp.xcodeproj -scheme CmuxMobileApp -configuration Debug \
    -destination "id=$ui_udid" -derivedDataPath "$work/dd-ui" -resultBundlePath "$work/ui.xcresult" \
    -only-testing:CmuxMobileAppUITests/ComposerKeyboardPinUITests \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= >"$out/uitest.log" 2>&1
  ui_status=$?
  set -e
  ui_counts="$(xcrun xcresulttool get test-results summary --path "$work/ui.xcresult" --compact 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("passed %s, failed %s, skipped %s" % (d.get("passedTests"), d.get("failedTests"), d.get("skippedTests")))
' || echo "no result bundle")"
  xcrun xcresulttool get test-results tests --path "$work/ui.xcresult" --compact > "$out/uitest-results.json" 2>/dev/null || true
  grep -E "error:|failed|passed|\*\* TEST" "$out/uitest.log" | tail -30 > "$out/uitest-tail.txt" || true
  note "- ComposerKeyboardPinUITests: exit $ui_status, $ui_counts, $((SECONDS - t0)) s"
  xcrun simctl shutdown "$ui_udid" >/dev/null 2>&1 || true
fi

# --- Captures: NAME|args per line in .fleet-scratch/r00-captures ---
if [[ -f .fleet-scratch/r00-captures && -n "$axe" ]]; then
  cap_udid="$(xcrun simctl create "r00-cap-${CMUX_CI_STEP_KEY:-local}" "$device_type" "$runtime")"
  r00_devs+=("$cap_udid")
  xcrun simctl boot "$cap_udid"; xcrun simctl bootstatus "$cap_udid" -b >/dev/null
  xcrun simctl install "$cap_udid" "$app"
  kbd_up() {
    "$axe" describe-ui --udid "$cap_udid" 2>/dev/null | python3 -c '
import json, sys
hit = False
def walk(n):
    global hit
    for k in ("AXLabel", "type", "role"):
        v = n.get(k)
        if isinstance(v, str) and v.lower() in ("space", "return", "keyboard", "next keyboard", "dictate"): hit = True
    for c in n.get("children") or []: walk(c)
try:
    for n in json.load(sys.stdin): walk(n)
except Exception: pass
sys.exit(0 if hit else 1)'
  }
  shot() { sleep "${2:-1.2}"; xcrun simctl io "$cap_udid" screenshot "$out/screens/$1.png" >/dev/null; }
  top() { for _ in 1 2; do "$axe" tap -x 200 -y 12 --udid "$cap_udid" >/dev/null 2>&1 || true; sleep 0.8; done; }
  open_kbd() {
    for id in chat.composer.field conversation.composer.text terminal.composer.field; do
      "$axe" tap --id "$id" --wait-timeout 2 --udid "$cap_udid" >/dev/null 2>&1 && { echo "$id"; return 0; }
    done
    return 1
  }
  close_kbd() {
    for _ in 1 2 3; do
      kbd_up || return 0
      "$axe" swipe --start-x 200 --start-y 300 --end-x 200 --end-y 760 --duration 0.5 --udid "$cap_udid" >/dev/null 2>&1 || true
      sleep 1
    done
  }
  while IFS='|' read -r name args; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    for look in light dark; do
      xcrun simctl ui "$cap_udid" appearance "$look" >/dev/null 2>&1 || true
      xcrun simctl terminate "$cap_udid" "$bundle_id" >/dev/null 2>&1 || true
      # shellcheck disable=SC2086
      SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 xcrun simctl launch "$cap_udid" "$bundle_id" -cmuxMobile.setupComplete YES $args >/dev/null
      sleep 8
      p="$name-$look"
      init_kbd=closed; kbd_up && init_kbd=open
      shot "$p-0-initial" 0.2
      close_kbd; shot "$p-1-kbd-closed"
      top; shot "$p-2-kbd-closed-top"
      field="$(open_kbd || true)"
      if [[ -n "$field" ]]; then
        sleep 1.5; shot "$p-3-kbd-open"
        top; shot "$p-4-kbd-open-top"
        opened=yes; kbd_up || opened="tapped $field but no keyboard seen"
      else
        opened="no composer field on this screen"
      fi
      note "- capture $p: initial keyboard $init_kbd; open: ${field:-none} ($opened)"
    done
  done < .fleet-scratch/r00-captures
  xcrun simctl terminate "$cap_udid" "$bundle_id" >/dev/null 2>&1 || true
fi
r00_cleanup
