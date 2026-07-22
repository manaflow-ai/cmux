#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY="usr-bin-roygbiv/cmux"
readonly WORKFLOW="memory-autoresearch.yml"
readonly REQUIRED_GH_CONFIG_DIR="/home/zac/.config/gh-usr-bin-roygbiv"
export GH_CONFIG_DIR="$REQUIRED_GH_CONFIG_DIR"

usage() {
  cat <<'USAGE'
Usage: ./autoresearch.sh [options]

Dispatch the GitHub Actions memory autoresearch workflow, wait for it, and
 download its artifact. No build or benchmark runs on this machine.

Options:
  --source-ref REF     Source branch, tag, or SHA to measure (default: main)
  --workflow-ref REF   Branch containing the workflow and harness
                       (default: current local branch)
  --samples N          Timed snapshots per variant per iteration (default: 5)
  --iterations N       Repetitions of both snapshot variants (default: 3)
  --artifact-dir DIR   Download root (default: _artifacts/memory-autoresearch)
  --continuous         Repeat dispatch/watch/download until interrupted
  --interval SECONDS   Delay between completed runs in continuous mode
                       (default: 900; minimum: 60)
  -h, --help           Show this help

Single baseline example:
  ./autoresearch.sh --source-ref main

Single candidate example:
  ./autoresearch.sh --source-ref autoresearch/candidate

Explicit unattended repetition:
  ./autoresearch.sh --source-ref main --continuous --interval 1800

The dispatcher always uses repository usr-bin-roygbiv/cmux and
GH_CONFIG_DIR=/home/zac/.config/gh-usr-bin-roygbiv.
USAGE
}

fail() {
  echo "autoresearch: $*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [ -z "$value" ] || [[ "$value" == --* ]]; then
    fail "$option requires a value"
  fi
}

positive_integer() {
  local option="$1"
  local value="$2"
  case "$value" in
    ''|*[!0-9]*) fail "$option must be a positive integer" ;;
  esac
  [ "$value" -ge 1 ] || fail "$option must be at least 1"
}

source_ref="main"
workflow_ref=""
samples="5"
iterations="3"
artifact_root="_artifacts/memory-autoresearch"
continuous="false"
interval_seconds="900"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-ref)
      require_value "$1" "${2:-}"
      source_ref="$2"
      shift 2
      ;;
    --workflow-ref)
      require_value "$1" "${2:-}"
      workflow_ref="$2"
      shift 2
      ;;
    --samples)
      require_value "$1" "${2:-}"
      samples="$2"
      shift 2
      ;;
    --iterations)
      require_value "$1" "${2:-}"
      iterations="$2"
      shift 2
      ;;
    --artifact-dir)
      require_value "$1" "${2:-}"
      artifact_root="$2"
      shift 2
      ;;
    --continuous)
      continuous="true"
      shift
      ;;
    --interval)
      require_value "$1" "${2:-}"
      interval_seconds="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

command -v gh >/dev/null 2>&1 || fail "gh is required"
positive_integer --samples "$samples"
positive_integer --iterations "$iterations"
positive_integer --interval "$interval_seconds"
if [ "$continuous" = "true" ] && [ "$interval_seconds" -lt 60 ]; then
  fail "--interval must be at least 60 seconds in continuous mode"
fi

if [ -z "$workflow_ref" ]; then
  command -v git >/dev/null 2>&1 || fail "git is required to infer --workflow-ref"
  workflow_ref="$(git branch --show-current 2>/dev/null || true)"
  [ -n "$workflow_ref" ] || fail "could not infer workflow branch; pass --workflow-ref"
fi

mkdir -p "$artifact_root"
[ -d "$artifact_root" ] && [ -w "$artifact_root" ] \
  || fail "artifact directory is not writable: $artifact_root"

gh auth status --hostname github.com >/dev/null \
  || fail "gh is not authenticated with GH_CONFIG_DIR=$GH_CONFIG_DIR"

run_once() {
  local sequence="$1"
  local nonce
  local run_id=""
  local run_attempt=""
  local artifact_name
  local destination
  local watch_status=0
  local download_status=0

  nonce="memory-$(date -u +%Y%m%dT%H%M%SZ)-$$-$sequence"
  echo "Dispatching $WORKFLOW from $workflow_ref against source $source_ref"
  gh workflow run "$WORKFLOW" \
    --repo "$REPOSITORY" \
    --ref "$workflow_ref" \
    -f "source_ref=$source_ref" \
    -f "samples=$samples" \
    -f "iterations=$iterations" \
    -f "nonce=$nonce"

  for _attempt in $(seq 1 60); do
    run_id="$(
      gh run list \
        --repo "$REPOSITORY" \
        --workflow "$WORKFLOW" \
        --event workflow_dispatch \
        --limit 100 \
        --json databaseId,displayTitle \
        --jq "[.[] | select(.displayTitle | contains(\"$nonce\"))][0].databaseId // empty"
    )"
    [ -n "$run_id" ] && break
    sleep 2
  done
  [ -n "$run_id" ] || fail "dispatched run did not appear for nonce $nonce"

  echo "Watching run $run_id"
  gh run watch "$run_id" --repo "$REPOSITORY" --exit-status || watch_status=$?

  run_attempt="$(gh api "repos/$REPOSITORY/actions/runs/$run_id" --jq '.run_attempt')"
  positive_integer run_attempt "$run_attempt"
  artifact_name="memory-autoresearch-${run_id}-${run_attempt}"
  destination="$artifact_root/run-${run_id}-attempt-${run_attempt}"
  mkdir -p "$destination"
  gh run download "$run_id" \
    --repo "$REPOSITORY" \
    --name "$artifact_name" \
    --dir "$destination" \
    || download_status=$?

  if [ "$download_status" -ne 0 ]; then
    echo "autoresearch: artifact download failed for run $run_id" >&2
  else
    echo "Artifact: $destination"
    echo "Result:   $destination/memory-autoresearch.json"
  fi
  if [ "$watch_status" -ne 0 ]; then
    echo "autoresearch: workflow run $run_id failed; downloaded diagnostics when available" >&2
  fi
  [ "$watch_status" -eq 0 ] && [ "$download_status" -eq 0 ]
}

if [ "$continuous" = "false" ]; then
  run_once 1
  exit $?
fi

trap 'echo; echo "autoresearch: continuous mode interrupted"; exit 130' INT TERM
sequence=1
while true; do
  run_once "$sequence" || true
  sequence=$((sequence + 1))
  echo "Waiting ${interval_seconds}s before the next dispatch (Ctrl-C to stop)"
  sleep "$interval_seconds"
done
