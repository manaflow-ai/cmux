#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'resolve-workflow-run-id: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 5 ]]; then
  die "usage: $0 WORKFLOW_FILE REF HEAD_SHA STARTED_AT MIN_RUN_ID"
fi

workflow_file="$1"
expected_ref="$2"
expected_sha="$3"
started_at="$4"
minimum_run_id="$5"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
poll_interval="${POLL_INTERVAL_SECONDS:-5}"
wait_timeout="${WAIT_TIMEOUT_SECONDS:-300}"
clock_skew="${CLOCK_SKEW_SECONDS:-30}"

[[ "$workflow_file" =~ ^[A-Za-z0-9._-]+\.yml$ ]] ||
  die "workflow file must be a simple .yml filename"
[[ "$expected_ref" =~ ^[A-Za-z0-9._/-]+$ ]] ||
  die "workflow ref contains unsupported characters"
[[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]] ||
  die "head SHA is not a full commit SHA"
[[ "$started_at" =~ ^[0-9]+$ ]] || die "STARTED_AT must be an epoch"
[[ "$minimum_run_id" =~ ^[0-9]+$ ]] || die "MIN_RUN_ID must be numeric"
[[ "$poll_interval" =~ ^[0-9]+$ ]] || die "POLL_INTERVAL_SECONDS must be numeric"
[[ "$wait_timeout" =~ ^[0-9]+$ ]] || die "WAIT_TIMEOUT_SECONDS must be numeric"
[[ "$clock_skew" =~ ^[0-9]+$ ]] || die "CLOCK_SKEW_SECONDS must be numeric"

workflow_path=".github/workflows/$workflow_file"
runs_endpoint="repos/$repo/actions/workflows/$workflow_file/runs?event=workflow_dispatch&per_page=100"
deadline=$(( $(date +%s) + wait_timeout ))
if (( started_at > clock_skew )); then
  skew_started_at=$((started_at - clock_skew))
else
  skew_started_at=0
fi

trap 'die "wait cancelled"' INT TERM

find_run() {
  local payload
  if ! payload="$(gh api "$runs_endpoint")"; then
    return 1
  fi
  jq -r \
    --arg sha "$expected_sha" \
    --arg ref "$expected_ref" \
    --arg path "$workflow_path" \
    --argjson skew_started "$skew_started_at" \
    --argjson minimum "$minimum_run_id" \
    '
      [
        (.workflow_runs // [])[]
        | select(
            (.event // "") == "workflow_dispatch"
            and (.head_sha // "") == $sha
            and ((.head_branch // "") == $ref or (.head_branch // "") == ("refs/tags/" + $ref))
            and ((.id | tonumber) > $minimum)
            and (.path // "") == $path
          )
        | {
            run: .,
            created_at: (try (.created_at | fromdateiso8601) catch -1)
          }
      ]
      | map(select(.created_at >= $skew_started))
      | unique_by(.run.id | tonumber)
      | sort_by(.run.id | tonumber)
      | if length > 1 then
          "ambiguous"
        elif length == 1 then
          .[0].run.id
        else
          empty
        end
    ' <<<"$payload"
}

while :; do
  now=$(date +%s)
  (( now < deadline )) || die "no unique $workflow_file run appeared before timeout"
  candidate=""
  if candidate="$(find_run)" && [[ "$candidate" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$candidate"
    exit 0
  fi
  [[ "$candidate" == "ambiguous" ]] &&
    die "multiple matching $workflow_file runs appeared; refusing to guess"
  sleep "$poll_interval"
done
