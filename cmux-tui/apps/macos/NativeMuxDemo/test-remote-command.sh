#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_REMOTE_DEMO="$SCRIPT_DIR/run-remote-demo.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-remote-command-test.XXXXXX")"
FAKE_SSH="$TEST_ROOT/ssh"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

cat >"$FAKE_SSH" <<'FAKE'
#!/usr/bin/env bash
set +e
command="${*: -1}"
if [[ "${CMUX_FAKE_SSH_DROP_COMMAND:-0}" == "1" ]]; then
  exit 0
fi
/bin/sh -c "$command"
printf '%s' "${CMUX_FAKE_SSH_SUFFIX:-}" >&2
# Reproduce SSH servers that discard the remote command's exit status.
exit 0
FAKE
chmod 700 "$FAKE_SSH"

if [[ -f "$SCRIPT_DIR/remote-command.sh" ]]; then
  # shellcheck source=remote-command.sh
  source "$SCRIPT_DIR/remote-command.sh"
  CMUX_REMOTE_SSH_BINARY="$FAKE_SSH"
  CMUX_REMOTE_SSH_OPTIONS=()
  CMUX_REMOTE_HOST="fake-host"
  CMUX_REMOTE_RUN_ID="test"
  CMUX_REMOTE_TEMP_ROOT="$TEST_ROOT"
  remote_under_test() {
    cmux_remote_run "$@"
  }
else
  # The regression-test commit runs against the old inline transport helper.
  # Extract only those two functions so the launcher itself does not execute.
  eval "$(sed -n \
    -e '/^quote_remote_command() {/,/^}/p' \
    -e '/^remote_command() {/,/^}/p' \
    "$RUN_REMOTE_DEMO")"
  PATH="$TEST_ROOT:$PATH"
  # shellcheck disable=SC2034  # Referenced by the functions loaded through eval above.
  SSH_OPTIONS=()
  # shellcheck disable=SC2034  # Referenced by the functions loaded through eval above.
  REMOTE_HOST="fake-host"
  remote_under_test() {
    remote_command "$@"
  }
fi

set +e
remote_under_test /usr/bin/false
STATUS=$?
set -e
if [[ "$STATUS" != "1" ]]; then
  echo "A false remote command did not preserve status 1." >&2
  exit 1
fi

STDERR_FILE="$TEST_ROOT/stderr"
export CMUX_FAKE_SSH_SUFFIX="ssh-wrapper-stderr"
set +e
STDOUT="$(remote_under_test /bin/sh -c \
  'printf remote-stdout; printf remote-stderr >&2; exit 7' 2>"$STDERR_FILE")"
STATUS=$?
set -e
if [[ "$STATUS" != "7" || "$STDOUT" != "remote-stdout" \
  || "$(cat "$STDERR_FILE")" != "remote-stderrssh-wrapper-stderr" ]]; then
  echo "Remote stdout, stderr, or status was not preserved." >&2
  exit 1
fi
unset CMUX_FAKE_SSH_SUFFIX

export CMUX_FAKE_SSH_DROP_COMMAND=1
set +e
remote_under_test /usr/bin/true >/dev/null 2>"$STDERR_FILE"
STATUS=$?
set -e
unset CMUX_FAKE_SSH_DROP_COMMAND
if [[ "$STATUS" != "255" ]] \
  || ! grep -q 'SSH completed without a remote status frame' "$STDERR_FILE"; then
  echo "A missing remote status frame was not rejected." >&2
  exit 1
fi

echo "Remote command status framing passed."
