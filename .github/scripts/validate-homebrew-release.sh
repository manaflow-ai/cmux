#!/usr/bin/env bash

# Validate the release provenance consumed by update-homebrew.yml.
#
# This script deliberately fails closed.  It never trusts a tag name or a
# workflow_run payload until GitHub's API confirms the immutable run, tag, and
# release asset are the same object.  EXPECTED_* variables are used by the
# publisher job for a second, just-in-time validation before the tap push.

set -euo pipefail

readonly EXPECTED_REPOSITORY="manaflow-ai/cmux"
readonly EXPECTED_WORKFLOW_NAME="Release macOS app"
readonly EXPECTED_WORKFLOW_PATH=".github/workflows/release.yml"
readonly PUBLISHER_WORKFLOW_NAME="Update Homebrew Cask"
readonly PUBLISHER_WORKFLOW_PATH=".github/workflows/update-homebrew.yml"
# The compare endpoint includes one commit summary even with per_page=1.
# Bound every response so a GitHub API anomaly cannot exhaust the runner.
readonly MAX_API_BYTES=4194304
readonly MIN_ASSET_BYTES=1000000
readonly MAX_ASSET_BYTES=1073741824
readonly VERSION_REGEX='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly SHA_REGEX='^[0-9a-f]{40}$'
readonly DIGEST_REGEX='^sha256:[0-9a-f]{64}$'

fail() {
  echo "::error::$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command is missing: $1"
}

require_command gh
require_command jq

[[ "${GITHUB_REPOSITORY:-}" == "$EXPECTED_REPOSITORY" ]] || \
  fail "This publisher is restricted to $EXPECTED_REPOSITORY"
[[ -n "${GITHUB_EVENT_NAME:-}" ]] || fail "GITHUB_EVENT_NAME is missing"
[[ -r "${GITHUB_EVENT_PATH:-}" ]] || fail "GITHUB_EVENT_PATH is missing or unreadable"
[[ -n "${GH_TOKEN:-}" ]] || fail "GH_TOKEN is required for provenance validation"

event_name="$GITHUB_EVENT_NAME"
event_file="$GITHUB_EVENT_PATH"

[[ "${GITHUB_WORKFLOW:-}" == "$PUBLISHER_WORKFLOW_NAME" ]] || \
  fail "Unexpected Homebrew publisher workflow name: ${GITHUB_WORKFLOW:-}"
[[ "${GITHUB_WORKFLOW_SHA:-}" =~ $SHA_REGEX ]] || \
  fail "Homebrew publisher workflow SHA is not immutable"
[[ "${GITHUB_WORKFLOW_REF:-}" == "$EXPECTED_REPOSITORY/$PUBLISHER_WORKFLOW_PATH@refs/heads/main" ]] || \
  fail "Homebrew publisher workflow must execute from its protected main revision"

jq -e 'type == "object"' "$event_file" >/dev/null || \
  fail "GitHub event payload is not a JSON object"
event_repository="$(jq -r '.repository.full_name // empty' "$event_file")"
[[ "$event_repository" == "$EXPECTED_REPOSITORY" ]] || \
  fail "Event payload is not from $EXPECTED_REPOSITORY"

api_json() {
  local endpoint="$1"
  local output="$2"
  local temporary="${output}.tmp"
  rm -f "$temporary"
  if ! gh api \
    --hostname github.com \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$endpoint" >"$temporary"; then
    rm -f "$temporary"
    fail "GitHub API request failed: $endpoint"
  fi
  local bytes
  bytes="$(wc -c <"$temporary" | tr -d '[:space:]')"
  [[ "$bytes" =~ ^[0-9]+$ ]] || fail "GitHub API returned an invalid response size"
  (( bytes <= MAX_API_BYTES )) || fail "GitHub API response is too large: $endpoint"
  jq -e 'type == "object"' "$temporary" >/dev/null || \
    fail "GitHub API returned a non-object response: $endpoint"
  mv "$temporary" "$output"
}

emit() {
  local line="$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$line" >>"$GITHUB_OUTPUT"
  else
    printf '%s\n' "$line"
  fi
}

validate_expected() {
  local key="$1"
  local actual="$2"
  local expected="${!key-}"
  if [[ -n "$expected" && "$expected" != "$actual" ]]; then
    fail "$key does not match fresh GitHub metadata"
  fi
}

event_run_id=""
case "$event_name" in
  workflow_run)
    [[ "${GITHUB_REF:-}" == "refs/heads/main" ]] || \
      fail "workflow_run publisher must execute from the default main branch"
    [[ "$(jq -r '.action // empty' "$event_file")" == "completed" ]] || \
      fail "workflow_run publisher requires the completed activity"
    jq -e '.workflow_run | type == "object"' "$event_file" >/dev/null || \
      fail "workflow_run payload is missing workflow_run"
    event_run_id="$(jq -r '.workflow_run.id // empty' "$event_file")"
    ;;
  *)
    fail "Only completed Release macOS app workflow runs can publish Homebrew"
    ;;
esac

[[ "$event_run_id" =~ ^[1-9][0-9]*$ ]] || \
  fail "source workflow run ID must be a positive integer"

temporary_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/cmux-homebrew-provenance.XXXXXX")"
cleanup() {
  rm -rf "$temporary_root"
}
trap cleanup EXIT

workflow_file="$temporary_root/workflow.json"
run_file="$temporary_root/run.json"
ref_file="$temporary_root/ref.json"
compare_file="$temporary_root/compare.json"
release_file="$temporary_root/release.json"
asset_file="$temporary_root/asset.json"
latest_file="$temporary_root/latest.json"

api_json "repos/$GITHUB_REPOSITORY/actions/workflows/release.yml" "$workflow_file"
workflow_id="$(jq -r '.id // empty' "$workflow_file")"
[[ "$workflow_id" =~ ^[1-9][0-9]*$ ]] || fail "Release workflow has no valid ID"
jq -e \
  --arg name "$EXPECTED_WORKFLOW_NAME" \
  --arg path "$EXPECTED_WORKFLOW_PATH" \
  --argjson id "$workflow_id" \
  '.id == $id and .name == $name and .path == $path and .state == "active"' \
  "$workflow_file" >/dev/null || fail "Release workflow identity is not the expected active workflow"

api_json "repos/$GITHUB_REPOSITORY/actions/runs/$event_run_id" "$run_file"
jq -e \
  --argjson id "$event_run_id" \
  --arg name "$EXPECTED_WORKFLOW_NAME" \
  --arg path "$EXPECTED_WORKFLOW_PATH" \
  --arg repo "$EXPECTED_REPOSITORY" \
  --arg version_regex "$VERSION_REGEX" \
  --arg sha_regex "$SHA_REGEX" \
  --argjson workflow_id "$workflow_id" \
  '
    .id == $id and
    .name == $name and
    .path == $path and
    .workflow_id == $workflow_id and
    .event == "push" and
    .status == "completed" and
    .conclusion == "success" and
    (.run_attempt | type == "number" and . >= 1) and
    (.head_branch | type == "string" and test($version_regex)) and
    (.head_sha | type == "string" and test($sha_regex)) and
    (.repository | type == "object" and .full_name == $repo and
      (.id | type == "number" and . > 0)) and
    (.head_repository | type == "object" and .full_name == $repo and
      (.id | type == "number" and . > 0)) and
    (.head_repository.id == .repository.id) and
    (.pull_requests | type == "array" and length == 0) and
    (.head_commit | type == "object") and
    (.head_commit.id == .head_sha)
  ' "$run_file" >/dev/null || fail "Source run is not an exact successful same-repository release"

run_sha="$(jq -r '.head_sha' "$run_file")"
tag="$(jq -r '.head_branch' "$run_file")"
run_attempt="$(jq -r '.run_attempt' "$run_file")"
run_workflow_id="$(jq -r '.workflow_id' "$run_file")"
[[ "$run_workflow_id" == "$workflow_id" ]] || fail "Source run uses a different workflow ID"
[[ "$run_attempt" =~ ^[1-9][0-9]*$ ]] || fail "Source run has an invalid attempt number"
[[ "$run_sha" =~ $SHA_REGEX ]] || fail "Source run has an invalid head SHA"
[[ "$tag" =~ $VERSION_REGEX ]] || fail "Source run branch is not a stable release tag"

jq -e \
  --argjson id "$event_run_id" \
  --arg name "$EXPECTED_WORKFLOW_NAME" \
  --arg path "$EXPECTED_WORKFLOW_PATH" \
  --arg event "push" \
  --arg repo "$EXPECTED_REPOSITORY" \
  --arg sha "$run_sha" \
  --arg tag "$tag" \
  --argjson workflow_id "$workflow_id" \
  --argjson run_attempt "$run_attempt" \
  '
    .workflow_run.id == $id and
    .workflow_run.name == $name and
    .workflow_run.path == $path and
    .workflow_run.workflow_id == $workflow_id and
    .workflow_run.event == $event and
    .workflow_run.status == "completed" and
    .workflow_run.conclusion == "success" and
    .workflow_run.run_attempt == $run_attempt and
    .workflow_run.head_sha == $sha and
    .workflow_run.head_branch == $tag and
    (.workflow_run.repository | type == "object" and .full_name == $repo and
      (.id | type == "number" and . > 0)) and
    (.workflow_run.head_repository | type == "object" and .full_name == $repo and
      (.id | type == "number" and . > 0)) and
    (.workflow_run.head_repository.id == .workflow_run.repository.id)
  ' "$event_file" >/dev/null || fail "workflow_run payload does not match the queried source run"

version="${tag#v}"
canonical_url="https://github.com/$EXPECTED_REPOSITORY/releases/download/$tag/cmux-macos.dmg"

api_json "repos/$GITHUB_REPOSITORY/git/ref/tags/$tag" "$ref_file"
jq -e --arg ref "refs/tags/$tag" '.ref == $ref and (.object | type == "object")' "$ref_file" >/dev/null || \
  fail "Release tag ref is malformed"
ref_type="$(jq -r '.object.type // empty' "$ref_file")"
ref_sha="$(jq -r '.object.sha // empty' "$ref_file")"
[[ "$ref_sha" =~ $SHA_REGEX ]] || fail "Release tag ref has an invalid object SHA"
case "$ref_type" in
  commit)
    tag_sha="$ref_sha"
    ;;
  tag)
    tag_object_file="$temporary_root/tag-object.json"
    api_json "repos/$GITHUB_REPOSITORY/git/tags/$ref_sha" "$tag_object_file"
    jq -e --arg tag_sha "$ref_sha" \
      '.sha == $tag_sha and .object.type == "commit"' "$tag_object_file" >/dev/null || \
      fail "Annotated release tag does not point to a commit"
    tag_sha="$(jq -r '.object.sha // empty' "$tag_object_file")"
    [[ "$tag_sha" =~ $SHA_REGEX ]] || fail "Annotated release tag has an invalid commit SHA"
    ;;
  *)
    fail "Release tag has an unsupported object type"
    ;;
esac
[[ "$tag_sha" == "$run_sha" ]] || fail "Release tag does not resolve to the source run commit"

# A stable tag must already be reachable from protected main.  This prevents
# an otherwise valid same-repository tag push from executing release code that
# was never reviewed and merged into the product branch.
api_json "repos/$GITHUB_REPOSITORY/compare/main...$run_sha?per_page=1" "$compare_file"
jq -e \
  '(.status == "behind" or .status == "identical") and
   (.ahead_by | type == "number" and . == 0) and
   (.base_commit.sha | type == "string") and
   (.commits | type == "array")' "$compare_file" >/dev/null || \
  fail "Release tag commit is not an ancestor of protected main"

api_json "repos/$GITHUB_REPOSITORY/releases/tags/$tag" "$release_file"
jq -e \
  --arg tag "$tag" \
  '.tag_name == $tag and .draft == false and .prerelease == false and
   (.published_at | type == "string" and length > 0) and
   (.assets | type == "array")' "$release_file" >/dev/null || \
  fail "Release is not a published stable release for the source tag"

asset_count="$(jq --arg name "cmux-macos.dmg" '[.assets[] | select(.name == $name)] | length' "$release_file")"
[[ "$asset_count" == "1" ]] || fail "Release must contain exactly one cmux-macos.dmg asset"
asset_id="$(jq -r --arg name "cmux-macos.dmg" '.assets[] | select(.name == $name) | .id' "$release_file")"
asset_size="$(jq -r --arg name "cmux-macos.dmg" '.assets[] | select(.name == $name) | .size' "$release_file")"
asset_digest="$(jq -r --arg name "cmux-macos.dmg" '.assets[] | select(.name == $name) | .digest' "$release_file")"
asset_state="$(jq -r --arg name "cmux-macos.dmg" '.assets[] | select(.name == $name) | .state' "$release_file")"
asset_content_type="$(jq -r --arg name "cmux-macos.dmg" '.assets[] | select(.name == $name) | .content_type' "$release_file")"
asset_url="$(jq -r --arg name "cmux-macos.dmg" '.assets[] | select(.name == $name) | .browser_download_url' "$release_file")"
[[ "$asset_id" =~ ^[1-9][0-9]*$ ]] || fail "Release asset has an invalid ID"
[[ "$asset_size" =~ ^[0-9]+$ ]] || fail "Release asset has an invalid size"
# Bound the decimal length before Bash arithmetic, so a malformed API value
# cannot overflow the integer evaluator and accidentally pass the range check.
(( ${#asset_size} <= ${#MAX_ASSET_BYTES} )) || fail "Release DMG size is too large"
(( asset_size >= MIN_ASSET_BYTES && asset_size <= MAX_ASSET_BYTES )) || \
  fail "Release DMG size is outside the safe range"
[[ "$asset_digest" =~ $DIGEST_REGEX ]] || fail "Release DMG has no verified SHA-256 digest"
[[ "$asset_state" == "uploaded" ]] || fail "Release DMG is not uploaded"
case "$asset_content_type" in
  application/x-apple-diskimage|application/octet-stream)
    ;;
  *)
    fail "Release DMG has an unexpected content type"
    ;;
esac
[[ "$asset_url" == "$canonical_url" ]] || fail "Release DMG URL is not canonical"

# The release response and the asset endpoint must describe the same object.
# This catches a replacement between the two API reads before any download.
api_json "repos/$GITHUB_REPOSITORY/releases/assets/$asset_id" "$asset_file"
jq -e \
  --argjson id "$asset_id" \
  --arg name "cmux-macos.dmg" \
  --arg state "$asset_state" \
  --argjson size "$asset_size" \
  --arg digest "$asset_digest" \
  --arg url "$canonical_url" \
  '.id == $id and .name == $name and .state == $state and .size == $size and
   .digest == $digest and .browser_download_url == $url' "$asset_file" >/dev/null || \
  fail "Release asset metadata changed during validation"

# Keep the old no-rollback behavior, but decide it from GitHub's explicit
# latest stable release rather than from an unordered release list.
api_json "repos/$GITHUB_REPOSITORY/releases/latest" "$latest_file"
latest_tag="$(jq -r '.tag_name // empty' "$latest_file")"
jq -e '.draft == false and .prerelease == false and (.tag_name | type == "string")' "$latest_file" >/dev/null || \
  fail "GitHub latest release response is malformed"
skip="false"
if [[ "$latest_tag" != "$tag" ]]; then
  skip="true"
fi

validate_expected EXPECTED_SOURCE_RUN_ID "$event_run_id"
validate_expected EXPECTED_TAG "$tag"
validate_expected EXPECTED_VERSION "$version"
validate_expected EXPECTED_RELEASE_SHA "$run_sha"
validate_expected EXPECTED_ASSET_ID "$asset_id"
validate_expected EXPECTED_ASSET_SIZE "$asset_size"
validate_expected EXPECTED_ASSET_DIGEST "$asset_digest"
validate_expected EXPECTED_ASSET_URL "$canonical_url"
validate_expected EXPECTED_SKIP "$skip"

emit "skip=$skip"
emit "version=$version"
emit "tag=$tag"
emit "release_sha=$run_sha"
emit "source_run_id=$event_run_id"
emit "asset_id=$asset_id"
emit "asset_size=$asset_size"
emit "asset_digest=$asset_digest"
emit "asset_url=$canonical_url"

if [[ "$skip" == "true" ]]; then
  echo "Skipping stale Homebrew update: source tag $tag is not latest stable release ($latest_tag)"
else
  echo "Validated release $tag from workflow run $event_run_id at $run_sha"
fi
