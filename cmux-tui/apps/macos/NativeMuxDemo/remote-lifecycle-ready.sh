#!/usr/bin/env bash

# Wait for a remote demo launcher without charging binary transfer time to the
# shorter daemon-startup budget.
cmux_wait_for_remote_demo_ready() {
  local launcher_log="$1"
  local launcher_pid="$2"
  local transfer_attempts="$3"
  local startup_attempts="$4"
  local poll_seconds="$5"
  local phase="transfer"
  local remaining="$transfer_attempts"

  while (( remaining > 0 )); do
    if grep -q '^Ready\.' "$launcher_log"; then
      return 0
    fi
    if ! kill -0 "$launcher_pid" 2>/dev/null; then
      return 10
    fi
    if [[ "$phase" == "transfer" ]] \
      && grep -q '^Starting the PTY-owning Iroh daemon' "$launcher_log"; then
      phase="startup"
      remaining="$startup_attempts"
    fi
    remaining=$((remaining - 1))
    sleep "$poll_seconds"
  done

  if [[ "$phase" == "transfer" ]]; then
    return 20
  fi
  return 21
}
