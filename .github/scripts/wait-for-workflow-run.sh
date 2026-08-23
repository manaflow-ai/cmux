#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'wait-for-workflow-run: %s\n' "$*" >&2
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
wait_timeout="${WAIT_TIMEOUT_SECONDS:-1800}"
clock_skew="${CLOCK_SKEW_SECONDS:-30}"

[[ "$workflow_file" =~ ^[A-Za-z0-9._-]+\.yml$ ]] ||
  die "workflow file must be a simple .yml filename"
[[ "$expected_ref" =~ ^[A-Za-z0-9._/-]+$ ]] ||
  die "workflow ref contains unsupported characters"
[[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]] ||
  die "head SHA is not a full commit SHA: $expected_sha"
[[ "$started_at" =~ ^[0-9]+$ ]] || die "STARTED_AT must be an epoch"
[[ "$minimum_run_id" =~ ^[0-9]+$ ]] || die "MIN_RUN_ID must be numeric"
[[ "$poll_interval" =~ ^[0-9]+$ ]] || die "POLL_INTERVAL_SECONDS must be numeric"
[[ "$wait_timeout" =~ ^[0-9]+$ ]] || die "WAIT_TIMEOUT_SECONDS must be numeric"
[[ "$clock_skew" =~ ^[0-9]+$ ]] || die "CLOCK_SKEW_SECONDS must be numeric"

workflow_path=".github/workflows/$workflow_file"
runs_endpoint="repos/$repo/actions/workflows/$workflow_file/runs?event=workflow_dispatch&per_page=100"
deadline=$(( $(date +%s) + wait_timeout ))
run_id=""
if (( started_at > clock_skew )); then
  skew_started_at=$((started_at - clock_skew))
else
  skew_started_at=0
fi

trap 'die "wait cancelled"' INT TERM

ref_matches() {
  local branch="$1"
  [[ "$branch" == "$expected_ref" || "$branch" == "refs/tags/$expected_ref" ]]
}

find_run() {
  local payload
  if ! payload="$(gh api "$runs_endpoint")"; then
    return 1
  fi
  jq -r \
    --arg sha "$expected_sha" \
    --arg ref "$expected_ref" \
    --arg path "$workflow_path" \
    --argjson started "$started_at" \
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
      ] as $candidates
      | (
          [$candidates[] | select(.created_at >= $skew_started)]
          | unique_by(.run.id | tonumber)
          | sort_by(.run.id | tonumber)
        ) as $eligible
      | if ($eligible | length) > 1 then
          "ambiguous"
        elif ($eligible | length) == 1 then
          ($eligible[0].run.id // empty)
        else
          empty
        end
    ' <<<"$payload"
}

candidate=""
while [[ -z "$run_id" ]]; do
  now=$(date +%s)
  (( now < deadline )) || die "no new $workflow_file run appeared before timeout"
  if candidate="$(find_run)" && [[ "$candidate" =~ ^[0-9]+$ ]]; then
    run_id="$candidate"
    break
  elif [[ "$candidate" == "ambiguous" ]]; then
    die "multiple matching $workflow_file runs appeared; refusing to guess"
  fi
  sleep "$poll_interval"
done

run_endpoint="repos/$repo/actions/runs/$run_id"
while :; do
  now=$(date +%s)
  (( now < deadline )) || die "run $run_id did not complete before timeout"

  if ! details="$(gh api "$run_endpoint")"; then
    sleep "$poll_interval"
    continue
  fi
  IFS=$'\t' read -r status conclusion actual_path actual_sha actual_branch event <<<"$(
    jq -r '[.status, (.conclusion // "pending"), (.path // ""), (.head_sha // ""), (.head_branch // ""), (.event // "")] | @tsv' <<<"$details"
  )"

  [[ "$actual_path" == "$workflow_path" ]] ||
    die "run $run_id came from $actual_path, expected $workflow_path"
  [[ "$actual_sha" == "$expected_sha" ]] ||
    die "run $run_id head $actual_sha does not match expected $expected_sha"
  ref_matches "$actual_branch" ||
    die "run $run_id ref $actual_branch does not match expected $expected_ref"
  [[ "$event" == "workflow_dispatch" ]] ||
    die "run $run_id event $event is not workflow_dispatch"

  if [[ "$status" == "completed" ]]; then
    [[ "$conclusion" == "success" ]] ||
      die "run $run_id concluded $conclusion (https://github.com/$repo/actions/runs/$run_id)"
    printf 'wait-for-workflow-run: run %s completed with %s\n' "$run_id" "$conclusion" >&2
    printf '%s\t%s\n' "$run_id" "$conclusion"
    exit 0
  fi

  case "$status" in
    queued|in_progress|pending|waiting|requested)
      sleep "$poll_interval"
      ;;
    *)
      die "run $run_id has unexpected status $status"
      ;;
  esac
done
