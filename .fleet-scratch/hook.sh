# Scratch capture hook (sourced by the patched cmux-next-ios-sim.sh after the launch screenshot).
# .fleet-scratch/captures: one capture per line, `NAME|ENV=V ENV=V|launch args...`.
# Each is launched with mock auth (no real account or Mac data) and shot in light and dark.
if [[ -f .fleet-scratch/captures ]]; then
  while IFS='|' read -r cap_name cap_env cap_args; do
    [[ -z "$cap_name" || "$cap_name" == \#* ]] && continue
    for look in light dark; do
      simctl ui "$udid" appearance "$look" >/dev/null 2>&1 || true
      simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
      cap_envs=(SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1)
      for kv in $cap_env; do cap_envs+=("SIMCTL_CHILD_$kv"); done
      # shellcheck disable=SC2086
      env "${cap_envs[@]}" xcrun simctl --set "$sims" launch "$udid" "$bundle_id" -cmuxMobile.setupComplete YES $cap_args >/dev/null
      sleep "${CAP_SETTLE:-8}"
      if [[ -f .fleet-scratch/after-launch.sh ]]; then
        # shellcheck disable=SC1091
        source .fleet-scratch/after-launch.sh
      fi
      simctl io "$udid" screenshot "$out/screens/$cap_name-$look.png" >/dev/null
      note "- capture: screens/$cap_name-$look.png ($cap_env $cap_args)"
    done
  done < .fleet-scratch/captures
  simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
fi
