#!/usr/bin/env bash

# Run a short command over SSH without trusting SSH to propagate the remote
# process status. Some SSH account wrappers always exit zero, so the remote
# shell appends a randomly tagged status frame to stderr.

cmux_remote_quote_command() {
  local rendered=""
  local quoted
  local argument
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    rendered="${rendered:+$rendered }$quoted"
  done
  printf '%s\n' "$rendered"
}

cmux_remote_run() {
  local rendered
  local marker
  local wrapped
  local stderr_file
  local ssh_status
  local remote_status

  rendered="$(cmux_remote_quote_command "$@")"
  marker="CMUX_REMOTE_STATUS_${CMUX_REMOTE_RUN_ID}_$(openssl rand -hex 8)"
  stderr_file="$(mktemp "$CMUX_REMOTE_TEMP_ROOT/remote-command.XXXXXX")"
  wrapped="$rendered; cmux_remote_status=\$?; printf '\\036%s:%s\\037' '$marker' \"\$cmux_remote_status\" >&2; exit \"\$cmux_remote_status\""

  if "${CMUX_REMOTE_SSH_BINARY:-ssh}" "${CMUX_REMOTE_SSH_OPTIONS[@]}" \
    "$CMUX_REMOTE_HOST" "$wrapped" 2>"$stderr_file"; then
    ssh_status=0
  else
    ssh_status=$?
  fi

  remote_status="$(CMUX_REMOTE_STATUS_MARKER="$marker" /usr/bin/perl -0777 -ne '
    if (/\x1e\Q$ENV{CMUX_REMOTE_STATUS_MARKER}\E:([0-9]+)\x1f/s) {
      print $1;
    }
  ' "$stderr_file")"
  CMUX_REMOTE_STATUS_MARKER="$marker" /usr/bin/perl -0777 -pe '
    s/\x1e\Q$ENV{CMUX_REMOTE_STATUS_MARKER}\E:[0-9]+\x1f//s
  ' "$stderr_file" >&2
  rm -f -- "$stderr_file"

  if [[ ! "$remote_status" =~ ^([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$ ]]; then
    if (( ssh_status != 0 )); then
      return "$ssh_status"
    fi
    echo "SSH completed without a remote status frame." >&2
    return 255
  fi
  return "$remote_status"
}
