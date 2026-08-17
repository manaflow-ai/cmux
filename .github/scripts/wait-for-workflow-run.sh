#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'wait-for-workflow-run: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 4 ]]; then
  die "usage: $0 WORKFLOW_FILE REF HEAD_SHA RUN_ID"
fi

workflow_file="$1"
expected_ref="$2"
expected_sha="$3"
run_id="$4"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
wait_timeout="${WAIT_TIMEOUT_SECONDS:-1800}"

[[ "$workflow_file" =~ ^[A-Za-z0-9._-]+\.yml$ ]] ||
  die "workflow file must be a simple .yml filename"
[[ "$expected_ref" =~ ^[A-Za-z0-9._/-]+$ ]] ||
  die "workflow ref contains unsupported characters"
[[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]] ||
  die "head SHA is not a full commit SHA: $expected_sha"
[[ "$run_id" =~ ^[0-9]+$ ]] || die "RUN_ID must be numeric"
[[ "$wait_timeout" =~ ^[0-9]+$ ]] || die "WAIT_TIMEOUT_SECONDS must be numeric"

workflow_path=".github/workflows/$workflow_file"
run_endpoint="repos/$repo/actions/runs/$run_id"
timeout_command="${TIMEOUT_COMMAND:-timeout}"
command -v "$timeout_command" >/dev/null 2>&1 ||
  die "required timeout command is unavailable: $timeout_command"

ref_matches() {
  local branch="$1"
  [[ "$branch" == "$expected_ref" || "$branch" == "refs/tags/$expected_ref" ]]
}

read_details() {
  local parsed
  if ! details="$(gh api "$run_endpoint")"; then
    die "could not read workflow run $run_id"
  fi
  if ! parsed="$(
    jq -r '[.status, (.conclusion // "pending"), (.path // ""), (.head_sha // ""), (.head_branch // ""), (.event // "")] | @tsv' <<<"$details"
  )"; then
    die "workflow run $run_id returned invalid metadata"
  fi
  IFS=$'\t' read -r run_status run_conclusion actual_path actual_sha actual_branch event <<<"$parsed"

  [[ "$actual_path" == "$workflow_path" ]] ||
    die "run $run_id came from $actual_path, expected $workflow_path"
  [[ "$actual_sha" == "$expected_sha" ]] ||
    die "run $run_id head $actual_sha does not match expected $expected_sha"
  ref_matches "$actual_branch" ||
    die "run $run_id ref $actual_branch does not match expected $expected_ref"
  [[ "$event" == "workflow_dispatch" ]] ||
    die "run $run_id event $event is not workflow_dispatch"
}

watch_pid=""
cancel_watch() {
  if [[ -n "$watch_pid" ]] && kill -0 "$watch_pid" 2>/dev/null; then
    kill -TERM "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
  fi
}

on_cancel() {
  cancel_watch
  die "wait cancelled"
}

trap on_cancel INT TERM

# Validate the run identity before handing it to the CLI watcher. The run ID
# came directly from gh workflow run, so no list endpoint or race-prone
# discovery interval is needed.
read_details

set +e
"$timeout_command" \
  --foreground \
  --signal=TERM \
  --kill-after=10s \
  "${wait_timeout}s" \
  gh run watch --compact --exit-status --repo "$repo" "$run_id" >&2 &
watch_pid=$!
wait "$watch_pid"
watch_status=$?
watch_pid=""
set -e

if (( watch_status == 124 || watch_status == 137 )); then
  die "run $run_id did not complete before timeout"
fi

# Re-read the immutable identity and final conclusion after the watcher exits.
# A successful watcher must have observed a completed successful run; this
# second read keeps the output and failure message tied to GitHub's final state.
read_details
if [[ "$run_status" != "completed" ]]; then
  die "run $run_id watcher exited with status $watch_status before completion"
fi
[[ "$run_conclusion" == "success" ]] ||
  die "run $run_id concluded $run_conclusion (https://github.com/$repo/actions/runs/$run_id)"

printf 'wait-for-workflow-run: run %s completed with %s\n' "$run_id" "$run_conclusion" >&2
printf '%s\t%s\n' "$run_id" "$run_conclusion"
