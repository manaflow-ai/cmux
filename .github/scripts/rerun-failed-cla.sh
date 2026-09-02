#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$1"
  exit 1
}

# The job-level expression is the first gate. Repeat it here so a
# future edit to that expression cannot turn this token into a
# general-purpose workflow rerunner.
[[ "${EVENT_NAME}" == "issue_comment" ]] || fail "Unexpected event for CLA rerun"
[[ "${ISSUE_NUMBER}" =~ ^[1-9][0-9]*$ ]] || fail "Invalid issue number"
[[ "${PR_NUMBER}" == "${ISSUE_NUMBER}" ]] || fail "Issue and pull request numbers differ"
[[ "${COMMENT_BODY}" == "recheck" || "${COMMENT_BODY}" == "I have read the CLA Document v2.2 and I hereby sign the CLA" ]] || fail "Comment is not an accepted CLA trigger"
[[ "${COMMENT_CREATED_AT}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "Invalid comment timestamp"
[[ "${COMMENT_ID}" =~ ^[1-9][0-9]*$ ]] || fail "Comment ID is invalid"
[[ "${COMMENT_AUTHOR_ID}" =~ ^[1-9][0-9]*$ ]] || fail "Comment author ID is invalid"
[[ -n "${COMMENT_AUTHOR_LOGIN}" ]] || fail "Comment author is missing"
[[ "${COMMENT_AUTHOR_LOGIN}" != *$'\n'* && "${COMMENT_AUTHOR_LOGIN}" != *$'\r'* ]] || fail "Comment author is malformed"
[[ "${COMMENT_AUTHOR_TYPE}" == "User" ]] || fail "Comment author is not a human user"
case "${COMMENT_AUTHOR_LOGIN,,}" in
  *"[bot]") fail "Bot comments cannot trigger a CLA rerun" ;;
esac
case "${COMMENT_AUTHOR_ASSOCIATION}" in
  OWNER|MEMBER|COLLABORATOR|CONTRIBUTOR|FIRST_TIME_CONTRIBUTOR|FIRST_TIMER|NONE) ;;
  *) fail "Comment author association is invalid" ;;
esac
case "${SIGNATURE_RECORDED}" in
  true|false|'') ;;
  *) fail "The CLA action did not provide a valid signature result" ;;
esac
if [[ "${COMMENT_BODY}" == "I have read the CLA Document v2.2 and I hereby sign the CLA" &&
      "${SIGNATURE_RECORDED}" != "true" ]]; then
  fail "The signing comment did not result in a persisted signature"
fi
readonly EXPECTED_CLA_GENERATION='v2.2-action-212a0f2dd659b24b48a30ba35966e06dc41736af'
[[ "${CLA_GENERATION}" == "${EXPECTED_CLA_GENERATION}" ]] || fail "Unexpected CLA generation marker"
[[ "${WORKFLOW_SHA}" =~ ^[0-9a-f]{40}$ ]] || fail "Invalid trusted workflow revision"
checked_out_sha="$(git rev-parse HEAD 2>/dev/null)" || fail "Could not verify the trusted workflow checkout"
[[ "${checked_out_sha}" == "${WORKFLOW_SHA}" ]] || fail "The checkout is not the immutable workflow revision"
[[ "${WORKFLOW_PATH}" == ".github/workflows/cla.yml" ]] || fail "Unexpected CLA workflow path"
[[ -f .github/scripts/rerun-failed-cla.sh ]] || fail "The trusted CLA rerun helper is missing"

# These values are part of the trusted workflow contract. They are deliberately
# constants, not event or comment input, so a contributor cannot redirect this
# check to a different ledger.
readonly SIGNATURES_BRANCH='cla-signatures'
readonly SIGNATURES_PATH='signatures/version2/cla.json'
readonly MAX_RUN_PAGES=10
readonly MAX_CHECK_PAGES=2
# Keep every GitHub JSON response below a fixed byte budget before it enters a
# shell variable. GitHub's pagination limits bound item counts, not the size of
# individual fields, so a response-size guard is still required.
readonly MAX_API_RESPONSE_BYTES=2000000
readonly MAX_API_ERROR_BYTES=65536
readonly MAX_LEDGER_BYTES=1000000
readonly MAX_LEDGER_SIGNATURES=10000
# GitHub wraps Contents API Base64 responses with newlines. Allow that
# transport overhead while bounding the raw field before normalization.
readonly MAX_LEDGER_RAW_BYTES=2000000
# These rendered job names are part of the v3 workflow contract. Keep them
# fixed here so a workflow edit cannot make this actions:write helper rerun an
# arbitrary failed job. The writer and compatibility jobs are optional failed
# members because a recheck can target a result-only failure; when either is
# failed, rerun-failed-jobs refreshes every failed v3 context together.
readonly CLA_ASSISTANT_JOB='CLA Assistant v3'
readonly CLA_WRITER_JOB='CLA ledger writer'
readonly CLA_COMPATIBILITY_JOB='CLA Assistant'
readonly CLA_COMPATIBILITY_STEP='Mirror CLA Assistant compatibility result'
readonly CLA_WORKFLOW_NAME='CLA Assistant v3'
readonly CLA_ACTION_APP_ID=15368

# Capture one byte past the limit in a temporary file. This keeps an oversized
# response out of shell memory and bounds disk use before command substitution
# can expose the response to jq. Bound stderr separately because GitHub can
# include response text in gh diagnostics.
gh_api_bounded() {
  local temp_dir body_file response_bytes gh_status head_status cat_status
  local -a pipeline_status
  temp_dir="$(mktemp -d)" || return 1
  body_file="${temp_dir}/body"
  set +e
  gh api "$@" 2> >(head -c "${MAX_API_ERROR_BYTES}" >&2) |
    head -c "$((MAX_API_RESPONSE_BYTES + 1))" >"${body_file}"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  gh_status="${pipeline_status[0]:-1}"
  head_status="${pipeline_status[1]:-1}"
  response_bytes="$(LC_ALL=C wc -c <"${body_file}" | tr -d '[:space:]')"
  if [[ ! "${response_bytes}" =~ ^[0-9]+$ ]] || (( response_bytes > MAX_API_RESPONSE_BYTES )); then
    rm -rf -- "${temp_dir}"
    return 2
  fi
  if (( head_status != 0 )); then
    rm -rf -- "${temp_dir}"
    return 1
  fi
  cat "${body_file}"
  cat_status=$?
  rm -rf -- "${temp_dir}"
  if (( gh_status != 0 )); then
    return "${gh_status}"
  fi
  return "${cat_status}"
}

validate_triggering_signature_record() {
  local ledger_response ledger_content ledger_content_compact ledger_json ledger_raw_bytes ledger_encoded_bytes ledger_decoded_bytes
  ledger_response="$(gh_api_bounded \
    --method GET \
    --header 'Accept: application/vnd.github+json' \
    --raw-field ref="${SIGNATURES_BRANCH}" \
    "repos/${GH_REPO}/contents/${SIGNATURES_PATH}" 2>/dev/null)" || fail "Could not query the trusted CLA signature ledger"
  jq -e '.type == "file" and .encoding == "base64" and (.content | type == "string") and (.content | length > 0)' <<<"${ledger_response}" >/dev/null || fail "The trusted CLA signature ledger response is malformed"
  ledger_content="$(jq -r '.content' <<<"${ledger_response}")"
  ledger_raw_bytes="$(printf '%s' "${ledger_content}" | wc -c | tr -d '[:space:]')"
  [[ "${ledger_raw_bytes}" =~ ^[0-9]+$ ]] || fail "Could not measure the trusted CLA signature ledger"
  (( ledger_raw_bytes <= MAX_LEDGER_RAW_BYTES )) || fail "The trusted CLA signature ledger response is too large"
  # The Contents API inserts line breaks into Base64 content. Remove only
  # transport whitespace before applying the encoded-size limit; otherwise a
  # valid near-limit ledger is rejected solely because it is wrapped.
  ledger_content_compact="$(printf '%s' "${ledger_content}" | LC_ALL=C tr -d '[:space:]')"
  [[ "${ledger_content_compact}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || fail "The trusted CLA signature ledger is not valid base64"
  ledger_encoded_bytes="$(printf '%s' "${ledger_content_compact}" | wc -c | tr -d '[:space:]')"
  [[ "${ledger_encoded_bytes}" =~ ^[0-9]+$ ]] || fail "Could not measure the trusted CLA signature ledger"
  (( ledger_encoded_bytes % 4 == 0 )) || fail "The trusted CLA signature ledger is not valid base64"
  # The maintained action rejects ledgers larger than 1 MB. Enforce the same
  # bound before decoding, so a malformed Contents response cannot make this
  # privileged job retain an unbounded payload.
  (( ledger_encoded_bytes <= ((MAX_LEDGER_BYTES + 2) * 4 / 3 + 4) )) || fail "The trusted CLA signature ledger exceeds the 1 MB limit; ask an administrator to compact or migrate it before signing"
  if ! ledger_json="$(
    if base64 --decode >/dev/null 2>&1 <<<''; then
      printf '%s' "${ledger_content_compact}" | base64 --decode
    else
      printf '%s' "${ledger_content_compact}" | base64 -D
    fi
  )"; then
    fail "The trusted CLA signature ledger is not valid base64"
  fi
  ledger_decoded_bytes="$(printf '%s' "${ledger_json}" | wc -c | tr -d ' ')"
  [[ "${ledger_decoded_bytes}" =~ ^[0-9]+$ ]] || fail "Could not measure the decoded CLA signature ledger"
  (( ledger_decoded_bytes <= MAX_LEDGER_BYTES )) || fail "The trusted CLA signature ledger exceeds the 1 MB limit; ask an administrator to compact or migrate it before signing"
  jq -e \
    --arg login "${COMMENT_AUTHOR_LOGIN}" \
    --argjson id "${COMMENT_AUTHOR_ID}" \
    --argjson comment_id "${COMMENT_ID}" \
    --arg created_at "${COMMENT_CREATED_AT}" \
    --argjson repo_id "${repo_id}" \
    --argjson pr_number "${PR_NUMBER}" \
    --argjson max_signatures "${MAX_LEDGER_SIGNATURES}" \
    'type == "object" and
     (.signedContributors | type == "array") and
     (.signedContributors | length <= $max_signatures) and
     any(.signedContributors[]?;
       (.name | type == "string") and .name == $login and
       (.id | type == "number") and .id == $id and
       (.comment_id | type == "number") and .comment_id == $comment_id and
       (.created_at | type == "string") and .created_at == $created_at and
       (.repoId | type == "number") and .repoId == $repo_id and
       (.pullRequestNo | type == "number") and .pullRequestNo == $pr_number
     )' <<<"${ledger_json}" >/dev/null || fail "The signing comment was not the signature persisted by the CLA action"
}

issue_json="$(gh_api_bounded "repos/${GH_REPO}/issues/${PR_NUMBER}" 2>/dev/null)" || fail "Could not query the issue"
issue_state="$(jq -r '.state // empty' <<<"${issue_json}")"
issue_pr_url="$(jq -r '.pull_request.url // empty' <<<"${issue_json}")"
[[ "${issue_state}" == "open" ]] || fail "The issue is not an open pull request"
[[ "${issue_pr_url}" == "https://api.github.com/repos/${GH_REPO}/pulls/${PR_NUMBER}" ]] || fail "The issue is not the exact repository pull request"

# Re-fetch the triggering comment immediately before using its ledger entry.
# A comment can be edited or deleted after the writer records a signature; a
# stale event payload must never authorize a rerun of the failed check.
comment_json="$(gh_api_bounded "repos/${GH_REPO}/issues/comments/${COMMENT_ID}" 2>/dev/null)" || fail "Could not query the triggering comment"
jq -e \
  --arg issue_url "https://api.github.com/repos/${GH_REPO}/issues/${PR_NUMBER}" \
  --arg body "${COMMENT_BODY}" \
  --arg author_id "${COMMENT_AUTHOR_ID}" \
  --arg author_login "${COMMENT_AUTHOR_LOGIN}" \
  --arg author_type "${COMMENT_AUTHOR_TYPE}" \
  --arg created_at "${COMMENT_CREATED_AT}" \
  '.issue_url == $issue_url and
   .body == $body and
   (.user | type == "object") and
   (.user.id | type == "number") and
   (.user.id | tostring) == $author_id and
   .user.login == $author_login and
   .user.type == $author_type and
   .created_at == $created_at and
   .updated_at == $created_at' <<<"${comment_json}" >/dev/null || fail "The triggering CLA comment was edited, deleted, or moved"

pr_json="$(gh_api_bounded "repos/${GH_REPO}/pulls/${PR_NUMBER}" 2>/dev/null)" || fail "Could not query the pull request"
jq -e --arg repo "${GH_REPO}" --argjson number "${PR_NUMBER}" --arg base "${TARGET_BASE_REF}" '
  .number == $number and
  .state == "open" and
  .base.ref == $base and
  (.base.repo.id | type == "number") and
  .base.repo.full_name == $repo and
  (.base.sha | type == "string") and
  (.base.sha | test("^[0-9a-f]{40}$")) and
  (.head.sha | type == "string") and
  (.head.sha | test("^[0-9a-f]{40}$")) and
  (.head.repo.id | type == "number") and
  (.head.repo.full_name | type == "string") and
  (.user.login | type == "string") and
  (.user.id | type == "number")
' <<<"${pr_json}" >/dev/null || fail "The live pull request is not valid"
head_sha="$(jq -r '.head.sha' <<<"${pr_json}")"
head_ref="$(jq -r '.head.ref // empty' <<<"${pr_json}")"
head_repo="$(jq -r '.head.repo.full_name // empty' <<<"${pr_json}")"
head_repo_id="$(jq -r '.head.repo.id // empty' <<<"${pr_json}")"
base_sha="$(jq -r '.base.sha // empty' <<<"${pr_json}")"
repo_id="$(jq -r '.base.repo.id // empty' <<<"${pr_json}")"
pr_author_login="$(jq -r '.user.login // empty' <<<"${pr_json}")"
pr_author_id="$(jq -r '.user.id // empty' <<<"${pr_json}")"
[[ "${head_ref}" != "" && "${head_repo}" != "" ]] || fail "The pull request head repository is missing"
[[ "${head_ref}" != *$'\n'* && "${head_ref}" != *$'\r'* ]] || fail "The pull request head branch is malformed"
[[ "${head_repo}" != *$'\n'* && "${head_repo}" != *$'\r'* ]] || fail "The pull request head repository is malformed"
[[ "${head_repo_id}" =~ ^[1-9][0-9]*$ ]] || fail "The pull request head repository ID is missing"
[[ "${base_sha}" =~ ^[0-9a-f]{40}$ ]] || fail "The pull request base SHA is missing"
[[ "${repo_id}" =~ ^[1-9][0-9]*$ ]] || fail "The pull request base repository ID is missing"
[[ "${pr_author_login}" != "" ]] || fail "The pull request author is missing"
[[ "${pr_author_id}" =~ ^[1-9][0-9]*$ ]] || fail "The pull request author ID is missing"
if [[ "${COMMENT_BODY}" == "I have read the CLA Document v2.2 and I hereby sign the CLA" ]]; then
  validate_triggering_signature_record
fi
# A contributor may recheck their own pull request. A different
# commenter must be a trusted repository participant, which limits
# unauthenticated users to the harmless no-op path.
if [[ "${COMMENT_BODY}" == "recheck" && "${COMMENT_AUTHOR_ID}" != "${pr_author_id}" ]]; then
  case "${COMMENT_AUTHOR_ASSOCIATION}" in
    OWNER|MEMBER|COLLABORATOR) ;;
    *) fail "Only the pull request author or a trusted repository participant may request a CLA rerun" ;;
  esac
fi

# The workflow-run list can omit pull_requests for pull_request_target runs.
# Fetch the source-head associations once, allowing only GitHub's documented
# fork-only missing-commit response to fall through to the live PR check.
fetch_commit_associations() {
  local commit_sha="$1"
  local allow_missing="$2"
  local response error_text stderr_file page_count page2_count page2
  stderr_file="$(mktemp)" || return 1
  if response="$(gh_api_bounded \
    --method GET \
    --header 'Accept: application/vnd.github+json' \
    --raw-field per_page=100 \
    --raw-field page=1 \
    "repos/${GH_REPO}/commits/${commit_sha}/pulls" 2>"${stderr_file}")"; then
    :
  else
    error_text="${response}"$'\n'"$(head -c "${MAX_API_ERROR_BYTES}" "${stderr_file}" 2>/dev/null || true)"
    if [[ "${allow_missing}" == true ]] && (jq -e '
      ((.status == 404 or .status == "404") and
        (.message == "Not Found" or .message == "Resource not found")) or
      ((.status == 422 or .status == "422") and
        (.message | type == "string" and startswith("No commit found for SHA: ")))
    ' <<<"${response}" >/dev/null 2>&1 ||
      { grep -Eq 'HTTP 404' <<<"${error_text}" &&
        grep -Eq 'Not Found|Resource not found' <<<"${error_text}"; } ||
      { grep -Eq 'HTTP 422' <<<"${error_text}" &&
        grep -Eq 'No commit found for SHA: [0-9a-f]{40}' <<<"${error_text}"; }); then
      response='[]'
    else
      rm -f -- "${stderr_file}"
      return 1
    fi
  fi
  rm -f -- "${stderr_file}"
  jq -e 'type == "array"' <<<"${response}" >/dev/null || return 1
  page_count="$(jq -r 'length' <<<"${response}")"
  [[ "${page_count}" =~ ^[0-9]+$ ]] || return 1
  (( page_count <= 100 )) || return 1
  if (( page_count == 100 )); then
    page2="$(gh_api_bounded \
      --method GET \
      --header 'Accept: application/vnd.github+json' \
      --raw-field per_page=100 \
      --raw-field page=2 \
      "repos/${GH_REPO}/commits/${commit_sha}/pulls" 2>/dev/null)" || return 1
    jq -e 'type == "array"' <<<"${page2}" >/dev/null || return 1
    page2_count="$(jq -r 'length' <<<"${page2}")"
    [[ "${page2_count}" =~ ^[0-9]+$ ]] || return 1
    (( page2_count <= 100 )) || return 1
    response="$(jq -c --argjson page2 "${page2}" '. + $page2' <<<"${response}")"
    if (( page2_count == 100 )); then
      echo "::error::Too many pull request associations for this head after two pages" >&2
      return 1
    fi
  fi
  printf '%s\n' "${response}"
}

assert_exact_pr_association() {
  local associations="$1"
  local expected_sha="$2"
  jq -e \
    --arg repo "${GH_REPO}" \
    --arg pr "${PR_NUMBER}" \
    --arg sha "${expected_sha}" \
    --arg base "${TARGET_BASE_REF}" \
    --arg base_sha "${base_sha}" \
    --arg head_ref "${head_ref}" \
    --arg head_repo "${head_repo}" \
    --argjson head_repo_id "${head_repo_id}" \
    --argjson repo_id "${repo_id}" '
      any(.[]?;
        (.number | type == "number") and
        (.number | tostring) == $pr and
        .base.ref == $base and
        .base.repo.full_name == $repo and
        (.base.repo.id | type == "number") and
        .base.repo.id == $repo_id and
        (.base.sha | type == "string") and
        .base.sha == $base_sha and
        .head.ref == $head_ref and
        .head.sha == $sha and
        .head.repo.full_name == $head_repo and
        (.head.repo.id | type == "number") and
        .head.repo.id == $head_repo_id
      )
    ' <<<"${associations}" >/dev/null
}

if ! commit_prs_json="$(fetch_commit_associations "${head_sha}" true)"; then
  fail "Could not query pull request associations"
fi
if [[ "$(jq -r 'length' <<<"${commit_prs_json}")" != 0 ]]; then
  assert_exact_pr_association "${commit_prs_json}" "${head_sha}" || fail "The current head is not associated with this pull request"
elif [[ "${head_repo}" == "${GH_REPO}" ]]; then
  fail "The base-repository head has no pull request association"
fi

# A fork-only commit can be absent from the commit association API.
# Resolve it through the live open-PR list instead. The head filter
# is owner:ref, so the result must contain exactly one PR with the
# exact number, SHA, head repository, and base repository. This
# rejects duplicate or cross-PR matches before a run is selected,
# and the helper is called again immediately before the POST.
validate_live_open_head_association() {
  local head_owner head_name open_prs_page open_pr_count open_prs_json matching_open_prs_json open_association_count
  [[ "${head_repo}" == */* && "${head_repo}" != */*/* ]] || fail "The pull request head repository name is invalid"
  head_owner="${head_repo%%/*}"
  head_name="${head_repo#*/}"
  [[ -n "${head_owner}" && -n "${head_name}" ]] || fail "The pull request head repository name is invalid"
  open_prs_page="$(gh_api_bounded \
    --method GET \
    --header 'Accept: application/vnd.github+json' \
    --raw-field state=open \
    --raw-field base="${TARGET_BASE_REF}" \
    --raw-field head="${head_owner}:${head_ref}" \
    --raw-field per_page=100 \
    --raw-field page=1 \
    "repos/${GH_REPO}/pulls" 2>/dev/null)" || fail "Could not query live open pull requests for this head"
  jq -e 'type == "array"' <<<"${open_prs_page}" >/dev/null || fail "Could not validate live open pull requests"
  open_pr_count="$(jq -r 'length' <<<"${open_prs_page}")"
  [[ "${open_pr_count}" =~ ^[0-9]+$ ]] || fail "Could not count live open pull requests"
  (( open_pr_count <= 100 )) || fail "The live open pull request page is oversized"
  if (( open_pr_count == 100 )); then
    open_prs_page2="$(gh_api_bounded \
      --method GET \
      --header 'Accept: application/vnd.github+json' \
      --raw-field state=open \
      --raw-field base="${TARGET_BASE_REF}" \
      --raw-field head="${head_owner}:${head_ref}" \
      --raw-field per_page=100 \
      --raw-field page=2 \
      "repos/${GH_REPO}/pulls" 2>/dev/null)" || fail "Could not query live open pull requests page 2"
    jq -e 'type == "array"' <<<"${open_prs_page2}" >/dev/null || fail "Could not validate live open pull requests page 2"
    open_pr_count2="$(jq -r 'length' <<<"${open_prs_page2}")"
    [[ "${open_pr_count2}" =~ ^[0-9]+$ ]] || fail "Could not count live open pull requests page 2"
    (( open_pr_count2 <= 100 )) || fail "The live open pull request page is oversized"
    open_prs_page="$(jq -c --argjson page2 "${open_prs_page2}" '. + $page2' <<<"${open_prs_page}")"
    open_pr_count=$((open_pr_count + open_pr_count2))
    (( open_pr_count2 < 100 )) || fail "Too many open pull requests share this head after two pages; push a new head or ask an administrator to resolve the association before requesting a rerun"
  fi
  open_prs_json="$(jq -c '[.]' <<<"${open_prs_page}")"
  if ! matching_open_prs_json="$(jq -c \
      --arg repo "${GH_REPO}" \
      --arg sha "${head_sha}" \
      --arg base_sha "${base_sha}" \
      --arg base "${TARGET_BASE_REF}" \
      --arg head_ref "${head_ref}" \
      --arg head_repo "${head_repo}" \
      --argjson head_repo_id "${head_repo_id}" \
      --argjson repo_id "${repo_id}" '
        [ .[] | .[]?
          | select(
              (.number | type == "number") and
              .state == "open" and
              .base.ref == $base and
              .base.repo.full_name == $repo and
              (.base.repo.id | type == "number") and
              .base.repo.id == $repo_id and
              (.base.sha | type == "string") and
              .base.sha == $base_sha and
              .head.ref == $head_ref and
              .head.sha == $sha and
              .head.repo.full_name == $head_repo and
              (.head.repo.id | type == "number") and
              .head.repo.id == $head_repo_id
            )
        ]
        | sort_by(.number)
      ' <<<"${open_prs_json}")"; then
    fail "Could not validate live open pull request data"
  fi
  open_association_count="$(jq -r 'length' <<<"${matching_open_prs_json}")"
  [[ "${open_association_count}" =~ ^[0-9]+$ ]] || fail "Could not count live open pull request associations"
  [[ "${open_association_count}" == "1" ]] || fail "Expected exactly one open pull request for this head"
  jq -e --argjson number "${PR_NUMBER}" '.[0].number == $number' <<<"${matching_open_prs_json}" >/dev/null || fail "The live head is associated with a different pull request"
}
validate_live_open_head_association

# Use one immutable PR predicate for each re-read. Keeping base and source
# identity in one helper prevents a late check from validating fewer fields
# than the initial snapshot.
validate_exact_pr_snapshot() {
  local payload="$1"
  jq -e \
    --arg repo "${GH_REPO}" \
    --argjson number "${PR_NUMBER}" \
    --arg sha "${head_sha}" \
    --arg base_sha "${base_sha}" \
    --arg base "${TARGET_BASE_REF}" \
    --arg head_ref "${head_ref}" \
    --arg head_repo "${head_repo}" \
    --argjson head_repo_id "${head_repo_id}" \
    --argjson base_repo_id "${repo_id}" \
    --arg opener "${pr_author_login}" '
      .number == $number and
      .state == "open" and
      .base.ref == $base and
      .base.repo.full_name == $repo and
      .base.repo.id == $base_repo_id and
      (.base.sha | type == "string") and
      .base.sha == $base_sha and
      .head.sha == $sha and
      .head.ref == $head_ref and
      .head.repo.full_name == $head_repo and
      .head.repo.id == $head_repo_id and
      .user.login == $opener
    ' <<<"${payload}" >/dev/null
}

workflow_page="$(gh_api_bounded \
  --method GET \
  --header 'Accept: application/vnd.github+json' \
  --raw-field per_page=100 \
  --raw-field page=1 \
  "repos/${GH_REPO}/actions/workflows" 2>/dev/null)" || fail "Could not query repository workflows"
jq -e 'type == "object" and (.workflows | type == "array")' <<<"${workflow_page}" >/dev/null || fail "Could not validate repository workflows"
workflow_count="$(jq -r '.workflows | length' <<<"${workflow_page}")"
[[ "${workflow_count}" =~ ^[0-9]+$ ]] || fail "Could not count repository workflows"
(( workflow_count <= 100 )) || fail "The repository workflow page is oversized"
if (( workflow_count == 100 )); then
  workflow_page2="$(gh_api_bounded \
    --method GET \
    --header 'Accept: application/vnd.github+json' \
    --raw-field per_page=100 \
    --raw-field page=2 \
    "repos/${GH_REPO}/actions/workflows" 2>/dev/null)" || fail "Could not query repository workflows page 2"
  jq -e 'type == "object" and (.workflows | type == "array")' <<<"${workflow_page2}" >/dev/null || fail "Could not validate repository workflows page 2"
  workflow_count2="$(jq -r '.workflows | length' <<<"${workflow_page2}")"
  [[ "${workflow_count2}" =~ ^[0-9]+$ ]] || fail "Could not count repository workflows page 2"
  (( workflow_count2 <= 100 )) || fail "The repository workflow page is oversized"
  workflow_page="$(jq -c --argjson page2 "${workflow_page2}" '.workflows += $page2.workflows' <<<"${workflow_page}")"
  workflow_count=$((workflow_count + workflow_count2))
  (( workflow_count2 < 100 )) || fail "Too many active repository workflows after two pages; ask an administrator to reduce the workflow list before requesting a rerun"
fi
workflow_json="$(jq -c '[.]' <<<"${workflow_page}")"
workflow_id="$(jq -r --arg path "${WORKFLOW_PATH}" '[.[] | .workflows[]? | select(.path == $path and .state == "active") | .id] | if length == 1 then .[0] else empty end' <<<"${workflow_json}")"
[[ "${workflow_id}" =~ ^[1-9][0-9]*$ ]] || fail "The expected CLA workflow is not active"

# Search a bounded first page, then choose the newest completed
# failure created no later than this comment. Edited, reopened, and
# synchronize events can leave several eligible failures for one
# exact head, so sort by creation time and run ID and select the
# newest one. Every candidate is tied to the exact workflow path and event.
# When GitHub includes pull_requests on a run, bind the candidate to the exact
# PR object, including its source head and live base SHAs. GitHub can return an
# empty array for pull_request_target runs. Those candidates are accepted only
# when the run has complete source-repository metadata and its execution SHA is
# the live PR base SHA. Missing metadata cannot identify which fork produced a
# branch, so it is always rejected before any check is rerun.
runs_page="$(gh_api_bounded \
  --method GET \
  --header 'Accept: application/vnd.github+json' \
  --raw-field event="${TARGET_EVENT}" \
  --raw-field branch="${head_ref}" \
  --raw-field per_page=100 \
  --raw-field page=1 \
  "repos/${GH_REPO}/actions/workflows/${workflow_id}/runs" 2>/dev/null)" || fail "Could not query CLA workflow runs"
jq -e 'type == "object" and (.workflow_runs | type == "array")' <<<"${runs_page}" >/dev/null || fail "Could not validate CLA workflow runs"
run_count="$(jq -r '.workflow_runs | length' <<<"${runs_page}")"
[[ "${run_count}" =~ ^[0-9]+$ ]] || fail "Could not count CLA workflow runs"
(( run_count <= 100 )) || fail "The CLA workflow run page is oversized"
runs_json="$(jq -c '[.]' <<<"${runs_page}")"

# The API returns newest runs first. Probe additional bounded pages when the
# first page is full, so normal workflow history growth does not strand a
# failed check. GitHub documents a 1,000-result cap for filtered workflow-run
# queries, so ten 100-item pages cover the complete API result window. Search
# the complete bounded window before deciding whether it is full: a valid
# candidate on page ten is still actionable. If the window is full and no
# candidate matches, fail with an actionable message instead of pretending page
# 11 can reveal an unreported run. `runs_json` stays an array of response
# objects; the candidate query below flattens each `.workflow_runs` array
# explicitly.
page_count="${run_count}"
page_number=2
while (( page_count == 100 && page_number <= MAX_RUN_PAGES )); do
  next_runs_page="$(gh_api_bounded \
    --method GET \
    --header 'Accept: application/vnd.github+json' \
    --raw-field event="${TARGET_EVENT}" \
    --raw-field branch="${head_ref}" \
    --raw-field per_page=100 \
    --raw-field page="${page_number}" \
    "repos/${GH_REPO}/actions/workflows/${workflow_id}/runs" 2>/dev/null)" || fail "Could not query CLA workflow runs page ${page_number}"
  jq -e 'type == "object" and (.workflow_runs | type == "array")' <<<"${next_runs_page}" >/dev/null || fail "Could not validate CLA workflow runs page ${page_number}"
  page_count="$(jq -r '.workflow_runs | length' <<<"${next_runs_page}")"
  [[ "${page_count}" =~ ^[0-9]+$ ]] || fail "Could not count CLA workflow runs page ${page_number}"
  (( page_count <= 100 )) || fail "The CLA workflow returned an oversized run page"
  runs_json="$(jq -c --argjson next_page "${next_runs_page}" '. + [$next_page]' <<<"${runs_json}")"
  (( page_number++ ))
done
run_window_full=false
(( page_count == 100 )) && run_window_full=true

# `pull_requests` is optional for fork runs, but when GitHub sends it, the
# field must keep its documented array shape. Treat a changed or malformed
# response as an infrastructure error. Silently treating it as an unmatched
# run could strand a required failed check with no recovery path.
if ! jq -e '
  all(.[] | .workflow_runs[]?;
    (type == "object") and
    (.pull_requests == null or
     ((.pull_requests | type) == "array" and
      (.pull_requests | length <= 100)))
  )
' <<<"${runs_json}" >/dev/null; then
  fail "The CLA workflow returned malformed pull request associations"
fi

if ! candidate_list_json="$(jq -c \
    --arg path "${WORKFLOW_PATH}" \
    --arg event "${TARGET_EVENT}" \
    --arg sha "${head_sha}" \
    --arg base_sha "${base_sha}" \
    --arg workflow_id "${workflow_id}" \
    --arg pr "${PR_NUMBER}" \
    --arg repo "${GH_REPO}" \
    --arg head_repo "${head_repo}" \
    --argjson head_repo_id "${head_repo_id}" \
    --argjson repo_id "${repo_id}" \
    --arg base "${TARGET_BASE_REF}" \
    --arg head_ref "${head_ref}" \
    --arg workflow_name "${CLA_WORKFLOW_NAME}" \
    --arg before "${COMMENT_CREATED_AT}" '
      def run_binds_to_pr:
        (.pull_requests) as $raw_prs
        | (if $raw_prs == null then []
           elif ($raw_prs | type) == "array" then $raw_prs
           else null end) as $prs
        | if $prs == null then false
          elif ($prs | length > 100) then false
          elif ($prs | length) == 0 then
            .head_sha == $base_sha and
            .head_branch == $head_ref and
            (.head_repository | type) == "object" and
            .head_repository.full_name == $head_repo and
            (.head_repository.id | type == "number") and
            .head_repository.id == $head_repo_id
          else any($prs[]?;
            (.number | type == "number") and
            (.number | tostring) == $pr and
            .base.ref == $base and
            (.base.sha | type == "string") and
            (.base.sha | test("^[0-9a-f]{40}$")) and
            .base.sha == $base_sha and
            ((.base.repo.full_name // "") == "" or
             .base.repo.full_name == $repo) and
            (.base.repo.id | type == "number") and
            .base.repo.id == $repo_id and
            .head.ref == $head_ref and
            .head.sha == $sha and
            (.head.repo.id | type == "number") and
            .head.repo.id == $head_repo_id and
            ((.head.repo.full_name // "") == "" or
             .head.repo.full_name == $head_repo)
          )
          end;
      [ .[] | .workflow_runs[]?
        | select(
            .path == $path and
            .event == $event and
            (.workflow_id | type == "number") and
            .workflow_id == ($workflow_id | tonumber) and
            (.name | type == "string") and
            .name == $workflow_name and
            (.head_sha | type == "string") and
            (.head_sha | test("^[0-9a-f]{40}$")) and
            (.head_repository | type) == "object" and
            .head_repository.full_name == $head_repo and
            (.head_repository.id | type == "number") and
            .head_repository.id == $head_repo_id and
            (.id | type == "number") and
            .id > 0 and
            .status == "completed" and
            .conclusion == "failure" and
            (.created_at | type == "string") and
            (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
            .created_at <= $before and
            run_binds_to_pr
          )
      ]
      | sort_by([
          if ((.pull_requests | type) == "array" and (.pull_requests | length) > 0) then 3
          elif (.head_repository | type) == "object" and .head_sha == $base_sha then 2
          elif .head_sha == $sha then 1
          else 0 end,
          .created_at,
          .id
        ])
    ' <<<"${runs_json}")"; then
  fail "Could not validate CLA workflow run data"
fi
candidate_count="$(jq -r 'length' <<<"${candidate_list_json}")"
[[ "${candidate_count}" =~ ^[0-9]+$ ]] || fail "Could not count matching CLA workflow runs"
if [[ "${candidate_count}" == "0" ]]; then
  if [[ "${run_window_full}" == true ]]; then
    fail "The GitHub workflow-run result window is full after ${MAX_RUN_PAGES} pages and contains no matching failed CLA run; push a new commit or ask an administrator to prune old runs before requesting a rerun"
  fi
  # Do not silently treat a failed run with an empty association and incomplete
  # source metadata as a successful no-op. A branch name or a null repository
  # can describe another fork, so every such run gets an explicit fail-closed
  # error before the helper can return.
  empty_execution_mismatch_count="$(jq -r \
    --arg path "${WORKFLOW_PATH}" \
    --arg event "${TARGET_EVENT}" \
    --arg sha "${head_sha}" \
    --arg workflow_id "${workflow_id}" \
    --arg head_repo "${head_repo}" \
    --argjson head_repo_id "${head_repo_id}" \
    --arg head_ref "${head_ref}" \
    --arg workflow_name "${CLA_WORKFLOW_NAME}" \
    --arg before "${COMMENT_CREATED_AT}" \
    '[ .[] | .workflow_runs[]?
      | select(
          .path == $path and
          .event == $event and
          (.workflow_id | type == "number") and
          .workflow_id == ($workflow_id | tonumber) and
          (.name | type == "string") and
          .name == $workflow_name and
          (.head_sha | type == "string") and
          (.head_sha | test("^[0-9a-f]{40}$")) and
          (
            .head_sha != $sha or
            (.head_repository | type) != "object" or
            .head_repository.full_name != $head_repo or
            (.head_repository.id | type) != "number" or
            .head_repository.id != $head_repo_id
          ) and
          (.id | type == "number") and
          .id > 0 and
          .status == "completed" and
          .conclusion == "failure" and
          (.created_at | type == "string") and
          (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
          .created_at <= $before and
          .head_branch == $head_ref and
          (.pull_requests == null or
           ((.pull_requests | type) == "array" and
            (.pull_requests | length) == 0))
        )
    ] | length' <<<"${runs_json}")"
  [[ "${empty_execution_mismatch_count}" =~ ^[0-9]+$ ]] || fail "Could not count unbound CLA workflow runs"
  if (( empty_execution_mismatch_count > 0 )); then
    fail "The workflow run has no pull request association with complete source metadata and an exact execution SHA"
  fi

  # A populated association with an old base SHA is not an absent check. It is
  # a stale failed run that must fail closed, otherwise a later rerun could
  # execute policy against a different target revision. Count only an exact
  # PR/source identity and treat a missing or malformed association base SHA as
  # stale as well.
  stale_base_count="$(jq -r \
    --arg path "${WORKFLOW_PATH}" \
    --arg event "${TARGET_EVENT}" \
    --arg sha "${head_sha}" \
    --arg workflow_id "${workflow_id}" \
    --arg pr "${PR_NUMBER}" \
    --arg repo "${GH_REPO}" \
    --arg head_ref "${head_ref}" \
    --arg head_repo "${head_repo}" \
    --argjson head_repo_id "${head_repo_id}" \
    --argjson repo_id "${repo_id}" \
    --arg base "${TARGET_BASE_REF}" \
    --arg base_sha "${base_sha}" \
    --arg workflow_name "${CLA_WORKFLOW_NAME}" \
    --arg before "${COMMENT_CREATED_AT}" \
    '[ .[] | .workflow_runs[]?
      | select(
          .path == $path and
          .event == $event and
          (.workflow_id | type == "number") and
          .workflow_id == ($workflow_id | tonumber) and
          (.name | type == "string") and
          .name == $workflow_name and
          (.head_sha | type == "string") and
          (.head_sha | test("^[0-9a-f]{40}$")) and
          (.head_repository | type) == "object" and
          .head_repository.full_name == $head_repo and
          (.head_repository.id | type == "number") and
          .head_repository.id == $head_repo_id and
          (.id | type == "number") and
          .id > 0 and
          .status == "completed" and
          .conclusion == "failure" and
          (.created_at | type == "string") and
          (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
          .created_at <= $before and
          (.pull_requests | type) == "array" and
          (.pull_requests | length > 0) and
          any(.pull_requests[]?;
            (.number | type == "number") and
            (.number | tostring) == $pr and
            .base.ref == $base and
            .base.repo.full_name == $repo and
            (.base.repo.id | type == "number") and
            .base.repo.id == $repo_id and
            .head.ref == $head_ref and
            .head.sha == $sha and
            (.head.repo.id | type == "number") and
            .head.repo.id == $head_repo_id and
            .head.repo.full_name == $head_repo and
            (if (.base.sha | type) == "string"
             then ((.base.sha | test("^[0-9a-f]{40}$") | not) or .base.sha != $base_sha)
             else true
             end)
          )
        )
    ] | length' <<<"${runs_json}")"
  [[ "${stale_base_count}" =~ ^[0-9]+$ ]] || fail "Could not count stale CLA workflow base associations"
  if (( stale_base_count > 0 )); then
    fail "The failed CLA check is bound to an outdated or malformed pull request base SHA; push a new commit before requesting a rerun"
  fi
  # A run from before this workflow generation cannot be safely
  # rerun: GitHub reruns the old workflow revision, which could
  # execute the archived action or an obsolete policy. Distinguish
  # that migration case from a normal no-op after a successful CLA
  # check so contributors receive an actionable recovery path.
  stale_run_count="$(jq -r \
    --arg path "${WORKFLOW_PATH}" \
    --arg event "${TARGET_EVENT}" \
    --arg sha "${head_sha}" \
    --arg workflow_id "${workflow_id}" \
    --arg pr "${PR_NUMBER}" \
    --arg repo "${GH_REPO}" \
    --arg head_ref "${head_ref}" \
    --arg head_repo "${head_repo}" \
    --argjson head_repo_id "${head_repo_id}" \
    --argjson repo_id "${repo_id}" \
    --arg base "${TARGET_BASE_REF}" \
    --arg base_sha "${base_sha}" \
    --arg workflow_name "${CLA_WORKFLOW_NAME}" \
    --arg before "${COMMENT_CREATED_AT}" \
    'def run_binds_to_pr:
       (.pull_requests) as $raw_prs
       | (if $raw_prs == null then []
          elif ($raw_prs | type) == "array" then $raw_prs
          else null end) as $prs
       | if $prs == null then false
         elif ($prs | length > 100) then false
         elif ($prs | length) == 0 then
           .head_sha == $sha and
           .head_branch == $head_ref and
           (.head_repository | type) == "object" and
           .head_repository.full_name == $head_repo and
           (.head_repository.id | type == "number") and
           .head_repository.id == $head_repo_id
         else any($prs[]?;
           (.number | type == "number") and
           (.number | tostring) == $pr and
           .base.ref == $base and
           (.base.sha | type == "string") and
           (.base.sha | test("^[0-9a-f]{40}$")) and
           .base.sha == $base_sha and
           ((.base.repo.full_name // "") == "" or
            .base.repo.full_name == $repo) and
           (.base.repo.id | type == "number") and
           .base.repo.id == $repo_id and
           .head.ref == $head_ref and
           .head.sha == $sha and
           (.head.repo.id | type == "number") and
           .head.repo.id == $head_repo_id and
           ((.head.repo.full_name // "") == "" or
            .head.repo.full_name == $head_repo)
         )
         end;
     [ .[] | .workflow_runs[]?
      | select(
          .path == $path and
          .event == $event and
          (.workflow_id | type == "number") and
          .workflow_id == ($workflow_id | tonumber) and
          (.name | type == "string") and
          .name == $workflow_name and
          (.head_sha | type == "string") and
          (.head_sha | test("^[0-9a-f]{40}$")) and
          (.id | type == "number") and
          .id > 0 and
          .status == "completed" and
          .conclusion == "failure" and
          (.created_at | type == "string") and
          (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
          .created_at <= $before and
          run_binds_to_pr
        )
    ] | length' <<<"${runs_json}")"
  [[ "${stale_run_count}" =~ ^[0-9]+$ ]] || fail "Could not count stale CLA workflow runs"
  if (( stale_run_count > 0 )); then
    fail "The failed CLA check was created by an older workflow generation. Push a new commit or close and reopen this pull request to create a current-generation CLA check, then post the exact signing declaration again."
  fi
  # A valid signature can arrive after the check already passed. Keep this
  # path read-only and report the absence of a failed current-head run.
  echo "No failed CLA run exists for this pull request head"
  exit 0
fi
# candidate_list_json is sorted oldest-first above. The selected run
# is fully fetched and validated below before any state-changing API
# call, so multiple historical failures do not create ambiguity.
candidate_json="$(jq -c '.[-1]' <<<"${candidate_list_json}")"
run_id="$(jq -r '.id // empty' <<<"${candidate_json}")"
[[ "${run_id}" =~ ^[1-9][0-9]*$ ]] || fail "The selected CLA run ID is invalid"
run_execution_sha="$(jq -r '.head_sha // empty' <<<"${candidate_json}")"
[[ "${run_execution_sha}" =~ ^[0-9a-f]{40}$ ]] || fail "The selected CLA run execution SHA is invalid"
run_head_branch="$(jq -r '.head_branch // empty' <<<"${candidate_json}")"
[[ -n "${run_head_branch}" && "${run_head_branch}" != *$'\n'* && "${run_head_branch}" != *$'\r'* ]] || fail "The selected CLA run head branch is invalid"

# A run with a populated pull_requests array carries a source-PR association,
# but that association is still only discovery data. For pull_request_target,
# GitHub records the Actions check on the workflow execution SHA (normally the
# live PR base SHA), not on the untrusted source head. Empty associations need
# one extra branch: when GitHub omits or cannot prove the source repository and
# base execution SHA, require a failed check on the exact source head instead.
# The selected check always names the exact run and job in its details URL.

# These values are set by validate_run_source_binding before each check lookup.
# Keeping the lookup SHA separate from the PR source SHA avoids silently using
# the wrong commit when GitHub returns pull_request_target metadata.
CHECK_LOOKUP_SHA=""
CHECK_EXPECTED_SHA=""
CHECK_BINDING_MODE=""

fetch_check_runs_for_sha() {
  local commit_sha="$1"
  local check_name="$2"
  local response page_count page2 page2_count page=1
  response="$(gh_api_bounded \
    --method GET \
    --header 'Accept: application/vnd.github+json' \
    --raw-field check_name="${check_name}" \
    --raw-field app_id="${CLA_ACTION_APP_ID}" \
    --raw-field filter=all \
    --raw-field per_page=100 \
    --raw-field page="${page}" \
    "repos/${GH_REPO}/commits/${commit_sha}/check-runs" 2>/dev/null)" || return 1
  jq -e 'type == "object" and (.check_runs | type == "array")' <<<"${response}" >/dev/null || return 1
  page_count="$(jq -r '.check_runs | length' <<<"${response}")"
  [[ "${page_count}" =~ ^[0-9]+$ ]] || return 1
  (( page_count <= 100 )) || return 1
  while (( page_count == 100 && page < MAX_CHECK_PAGES )); do
    (( page++ ))
    page2="$(gh_api_bounded \
      --method GET \
      --header 'Accept: application/vnd.github+json' \
      --raw-field check_name="${check_name}" \
      --raw-field app_id="${CLA_ACTION_APP_ID}" \
      --raw-field filter=all \
      --raw-field per_page=100 \
      --raw-field page="${page}" \
      "repos/${GH_REPO}/commits/${commit_sha}/check-runs" 2>/dev/null)" || return 1
    jq -e 'type == "object" and (.check_runs | type == "array")' <<<"${page2}" >/dev/null || return 1
    page2_count="$(jq -r '.check_runs | length' <<<"${page2}")"
    [[ "${page2_count}" =~ ^[0-9]+$ ]] || return 1
    (( page2_count <= 100 )) || return 1
    response="$(jq -c --argjson page2 "${page2}" '.check_runs += $page2.check_runs' <<<"${response}")"
    page_count="${page2_count}"
  done
  (( page_count < 100 )) || return 1
  printf '%s\n' "${response}"
}

assert_failed_check_binding() {
  local checks="$1"
  local expected_run_id="$2"
  local expected_job_id="$3"
  local expected_check_sha="$4"
  local expected_check_name="$5"
  local details_url="https://github.com/${GH_REPO}/actions/runs/${expected_run_id}/job/${expected_job_id}"
  local matching_count
  [[ "${expected_check_sha}" =~ ^[0-9a-f]{40}$ ]] || return 1
  matching_count="$(jq -r \
    --arg job "${expected_check_name}" \
    --arg sha "${expected_check_sha}" \
    --arg url "${details_url}" \
    --argjson app_id "${CLA_ACTION_APP_ID}" '
      [ .check_runs[]?
        | select(
        (.id | type == "number") and
        .id > 0 and
        .name == $job and
        .status == "completed" and
        .conclusion == "failure" and
        (.head_sha | type == "string") and
        .head_sha == $sha and
        (.app | type == "object") and
        (.app.id | type == "number") and
        .app.id == $app_id and
        .app.slug == "github-actions" and
        (.details_url | type == "string") and
        (.details_url == $url or
         (.details_url | startswith($url + "?") or startswith($url + "#")))
        )
      ] | length
    ' <<<"${checks}")"
  [[ "${matching_count}" =~ ^[0-9]+$ && "${matching_count}" == 1 ]]
}

validate_failed_check_binding() {
  local expected_run_id="$1"
  local expected_job_id="$2"
  local expected_check_name="$3"
  local check_sha="${CHECK_LOOKUP_SHA}"
  local expected_check_sha="${CHECK_EXPECTED_SHA}"
  local checks
  [[ "${check_sha}" =~ ^[0-9a-f]{40}$ && "${expected_check_sha}" =~ ^[0-9a-f]{40}$ ]] ||
    fail "The selected CLA run has no valid check binding context"
  checks="$(fetch_check_runs_for_sha "${check_sha}" "${expected_check_name}")" ||
    fail "Could not query checks for the selected CLA execution"
  assert_failed_check_binding "${checks}" "${expected_run_id}" "${expected_job_id}" "${expected_check_sha}" "${expected_check_name}" ||
    if [[ "${CHECK_BINDING_MODE}" == source-fallback ]]; then
      fail "No failed CLA check is bound to the exact pull request source head and selected job"
    else
      fail "No failed CLA check is bound to the workflow execution SHA and selected job"
    fi
}

validate_run_source_binding() {
  local run_payload="$1"
  local execution_sha pull_requests_type pull_request_count head_repository_type
  execution_sha="$(jq -r '.head_sha // empty' <<<"${run_payload}")"
  [[ "${execution_sha}" =~ ^[0-9a-f]{40}$ ]] || fail "The workflow run execution SHA is invalid"
  CHECK_LOOKUP_SHA="${execution_sha}"
  CHECK_EXPECTED_SHA="${execution_sha}"
  CHECK_BINDING_MODE=execution
  pull_requests_type="$(jq -r 'if .pull_requests == null then "null" else (.pull_requests | type) end' <<<"${run_payload}")"
  case "${pull_requests_type}" in
    null) pull_request_count=0 ;;
    array) pull_request_count="$(jq -r '.pull_requests | length' <<<"${run_payload}")" ;;
    *) fail "The workflow run pull request association is malformed" ;;
  esac
  [[ "${pull_request_count}" =~ ^[0-9]+$ ]] || fail "The workflow run pull request association count is invalid"
  if (( pull_request_count == 0 )); then
    # GitHub may omit pull_requests on a pull_request_target run. A complete
    # source repository plus the live PR base SHA binds the run directly. A
    # null source repository cannot identify which fork produced the branch,
    # so it is never eligible for the source-head fallback.
    head_repository_type="$(jq -r 'if .head_repository == null then "null" else (.head_repository | type) end' <<<"${run_payload}")"
    case "${head_repository_type}" in
      null) fail "The workflow run source repository metadata is missing" ;;
      object)
        jq -e \
          --arg head_repo "${head_repo}" \
          --argjson head_repo_id "${head_repo_id}" \
          '.head_repository.full_name == $head_repo and
           (.head_repository.id | type == "number") and
           .head_repository.id == $head_repo_id' <<<"${run_payload}" >/dev/null ||
          fail "The workflow run source repository does not match the pull request"
        ;;
      *) fail "The workflow run source repository metadata is malformed" ;;
    esac
    validate_live_open_head_association
    if [[ "${execution_sha}" == "${base_sha}" ]]; then
      CHECK_LOOKUP_SHA="${execution_sha}"
      CHECK_EXPECTED_SHA="${execution_sha}"
      CHECK_BINDING_MODE=execution
    else
      # Some pull_request_target API responses expose a non-base execution
      # SHA. Bind those runs to the immutable live source head and its exact
      # job URL only after the complete repository metadata and live PR
      # association above have been verified.
      CHECK_LOOKUP_SHA="${head_sha}"
      CHECK_EXPECTED_SHA="${head_sha}"
      CHECK_BINDING_MODE=source-fallback
    fi
  fi
}

# Keep one exact run predicate for discovery rechecks and the final TOCTOU
# re-read. The list response is discovery only, never authorization.
validate_exact_run_payload() {
  local payload="$1"
  jq -e \
    --arg run_id "${run_id}" \
    --arg path "${WORKFLOW_PATH}" \
    --arg event "${TARGET_EVENT}" \
    --arg sha "${head_sha}" \
    --arg run_sha "${run_execution_sha}" \
    --arg run_head_branch "${run_head_branch}" \
    --arg pr "${PR_NUMBER}" \
    --arg repo "${GH_REPO}" \
    --arg head_repo "${head_repo}" \
    --argjson head_repo_id "${head_repo_id}" \
    --argjson repo_id "${repo_id}" \
    --arg head_ref "${head_ref}" \
    --arg workflow_id "${workflow_id}" \
    --arg workflow_name "${CLA_WORKFLOW_NAME}" \
    --arg base "${TARGET_BASE_REF}" \
    --arg base_sha "${base_sha}" \
    --arg before "${COMMENT_CREATED_AT}" '
      def run_binds_to_pr:
        (.pull_requests) as $raw_prs
        | (if $raw_prs == null then []
           elif ($raw_prs | type) == "array" then $raw_prs
           else null end) as $prs
        | if $prs == null then false
          elif ($prs | length) == 0 then
            .head_sha == $base_sha and
            .head_branch == $head_ref and
            (.head_repository | type) == "object" and
            .head_repository.full_name == $head_repo and
            (.head_repository.id | type == "number") and
            .head_repository.id == $head_repo_id
          else any($prs[]?;
            (.number | type == "number") and
            (.number | tostring) == $pr and
            .base.ref == $base and
            (.base.sha | type == "string") and
            (.base.sha | test("^[0-9a-f]{40}$")) and
            .base.sha == $base_sha and
            ((.base.repo.full_name // "") == "" or
             .base.repo.full_name == $repo) and
            (.base.repo.id | type == "number") and
            .base.repo.id == $repo_id and
            .head.ref == $head_ref and
            .head.sha == $sha and
            (.head.repo.id | type == "number") and
            .head.repo.id == $head_repo_id and
            ((.head.repo.full_name // "") == "" or
             .head.repo.full_name == $head_repo)
          )
          end;
      (.id | type == "number") and
      .id == ($run_id | tonumber) and
      (.workflow_id | type == "number") and
      .workflow_id == ($workflow_id | tonumber) and
      (.name | type == "string") and
      .name == $workflow_name and
      (.path | type == "string") and
      .path == $path and
      .event == $event and
      .status == "completed" and
      .conclusion == "failure" and
      .head_sha == $run_sha and
      .head_branch == $run_head_branch and
      (.head_repository | type) == "object" and
      .head_repository.full_name == $head_repo and
      (.head_repository.id | type == "number") and
      .head_repository.id == $head_repo_id and
      (.created_at | type == "string") and
      (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      .created_at <= $before and
      run_binds_to_pr
    ' <<<"${payload}" >/dev/null
}

# Re-read the individual run. The list response is only a discovery result.
run_json="$(gh_api_bounded "repos/${GH_REPO}/actions/runs/${run_id}" 2>/dev/null)" || fail "Could not query the selected CLA run"
validate_exact_run_payload "${run_json}" || fail "The selected run no longer matches the exact failed CLA check"
validate_run_source_binding "${run_json}"

# Close the main TOCTOU window. A push, close, or another rerun can
# happen while the API calls above run. Never rerun a stale head.
latest_pr_json="$(gh_api_bounded "repos/${GH_REPO}/pulls/${PR_NUMBER}" 2>/dev/null)" || fail "Could not recheck the pull request"
validate_exact_pr_snapshot "${latest_pr_json}" || fail "The pull request changed while selecting the CLA run"

# Ensure another queued invocation did not already rerun this run.
final_run_json="$(gh_api_bounded "repos/${GH_REPO}/actions/runs/${run_id}" 2>/dev/null)" || fail "Could not recheck the selected CLA run"
validate_exact_run_payload "${final_run_json}" || fail "The exact failed CLA run is no longer eligible"
validate_run_source_binding "${final_run_json}"

# Fetch the complete bounded job set for one exact run. The rerun endpoint
# requires actions:write, so discovery must fail closed if pagination or shape
# checks cannot prove that every failed job belongs to this CLA workflow.
# The workflow-run response is authoritative for workflow name, head branch,
# and source repository. GitHub's jobs endpoint does not document those fields
# and omits them in production, so job validation uses only its documented
# identity fields, plus optional source metadata when GitHub supplies it.
fetch_jobs_for_run() {
  local target_run_id="$1"
  local page_json page_count page2_json page2_count
  page_json="$(gh_api_bounded \
    --method GET \
    --header 'Accept: application/vnd.github+json' \
    --raw-field per_page=100 \
    --raw-field page=1 \
    "repos/${GH_REPO}/actions/runs/${target_run_id}/jobs" 2>/dev/null)" || return 1
  jq -e 'type == "object" and (.jobs | type == "array")' <<<"${page_json}" >/dev/null || return 1
  page_count="$(jq -r '.jobs | length' <<<"${page_json}")"
  [[ "${page_count}" =~ ^[0-9]+$ ]] || return 1
  (( page_count <= 100 )) || return 1
  if (( page_count == 100 )); then
    page2_json="$(gh_api_bounded \
      --method GET \
      --header 'Accept: application/vnd.github+json' \
      --raw-field per_page=100 \
      --raw-field page=2 \
      "repos/${GH_REPO}/actions/runs/${target_run_id}/jobs" 2>/dev/null)" || return 1
    jq -e 'type == "object" and (.jobs | type == "array")' <<<"${page2_json}" >/dev/null || return 1
    page2_count="$(jq -r '.jobs | length' <<<"${page2_json}")"
    [[ "${page2_count}" =~ ^[0-9]+$ ]] || return 1
    (( page2_count <= 100 )) || return 1
    page_json="$(jq -c --argjson page2 "${page2_json}" '.jobs += $page2.jobs' <<<"${page_json}")"
    (( page2_count < 100 )) || return 1
  fi
  jq -c '[.]' <<<"${page_json}"
}

jobs_json="$(fetch_jobs_for_run "${run_id}")" || fail "Could not query and validate jobs for the selected CLA run"
RERUN_TARGET_JOB_NAME=""
RERUN_FAILED_JOBS=false

# Validate every failed job before granting the state-changing API call. The
# v3 writer, required result, and migration compatibility jobs are the only
# failures this helper may replay. If the writer or compatibility job failed,
# use the failed-jobs endpoint so GitHub refreshes every head-bound context;
# otherwise replay only the required result job. Any extra failure,
# cancellation, malformed job, or stale source identity aborts the request.
validate_failed_job_set() {
  local payload="$1"
  local all_jobs_json failed_jobs_json failed_count nonfailure_count
  local unexpected_count assistant_count assistant_valid_count assistant_failed_count assistant_success_count
  local writer_count writer_valid_count
  local compatibility_count compatibility_valid_count
  if ! all_jobs_json="$(jq -c '[.[] | .jobs[]?]' <<<"${payload}")"; then
    fail "Could not flatten jobs for the selected CLA run"
  fi
  jq -e \
    --arg run_id "${run_id}" \
    'type == "array" and all(.[];
      (.id | type == "number") and
      .id > 0 and
      (.run_id | type == "number") and
      .run_id == ($run_id | tonumber) and
      (.name | type == "string") and
      (.status == "completed") and
      (.conclusion | type == "string") and
      (.head_sha | type == "string") and
      (.head_sha | test("^[0-9a-f]{40}$")) and
      (.steps | type == "array") and
      (.steps | length <= 100) and
      all(.steps[]?; type == "object") and
      ((has("head_repository") | not) or
       .head_repository == null or
       ((.head_repository | type) == "object" and
        (.head_repository.full_name | type) == "string" and
        (.head_repository.id | type == "number"))) and
      ((has("workflow_name") | not) or
       (.workflow_name | type) == "string") and
      ((has("workflow_id") | not) or
       (.workflow_id | type == "number"))
    )' <<<"${all_jobs_json}" >/dev/null || fail "The selected CLA run contains a malformed or incomplete job"

  failed_jobs_json="$(jq -c '[.[] | select(.conclusion != "success" and .conclusion != "skipped")]' <<<"${all_jobs_json}")"
  failed_count="$(jq -r 'length' <<<"${failed_jobs_json}")"
  [[ "${failed_count}" =~ ^[0-9]+$ ]] || fail "Could not count failed jobs for the selected CLA run"
  nonfailure_count="$(jq -r '[.[] | select(.conclusion != "failure")] | length' <<<"${failed_jobs_json}")"
  (( nonfailure_count == 0 )) || fail "The selected CLA run contains a cancelled or non-failure job; refusing to rerun it"
  unexpected_count="$(jq -r \
    --arg assistant_job "${CLA_ASSISTANT_JOB}" \
    --arg writer_job "${CLA_WRITER_JOB}" \
    --arg compatibility_job "${CLA_COMPATIBILITY_JOB}" \
    '[.[] | select(.name != $assistant_job and .name != $writer_job and .name != $compatibility_job)] | length' \
    <<<"${failed_jobs_json}")"
  (( unexpected_count == 0 )) || fail "The selected CLA run contains an unexpected failed job; refusing to rerun it"

  # The v3 job is the generation anchor even when only the compatibility
  # mirror failed. Validate exactly one current-generation v3 job across the
  # whole run, then select a failed v3 or compatibility job below.
  if ! assistant_count="$(jq -r \
      --arg assistant_job "${CLA_ASSISTANT_JOB}" \
      '[.[] | select(.name == $assistant_job)] | length' <<<"${all_jobs_json}")" ||
     ! assistant_failed_count="$(jq -r \
       --arg assistant_job "${CLA_ASSISTANT_JOB}" \
       '[.[] | select(.name == $assistant_job)] | length' <<<"${failed_jobs_json}")" ||
     ! assistant_success_count="$(jq -r \
       --arg assistant_job "${CLA_ASSISTANT_JOB}" \
       '[.[] | select(.name == $assistant_job and .conclusion == "success")] | length' <<<"${all_jobs_json}")" ||
     ! assistant_valid_count="$(jq -r \
       --arg run_id "${run_id}" \
       --arg run_sha "${run_execution_sha}" \
       --arg head_repo "${head_repo}" \
       --argjson head_repo_id "${head_repo_id}" \
       --arg assistant_job "${CLA_ASSISTANT_JOB}" \
       --arg workflow_name "${CLA_WORKFLOW_NAME}" \
       --arg workflow_id "${workflow_id}" \
       --arg generation_step "CLA generation ${CLA_GENERATION}" \
       '[.[] | select(
          .name == $assistant_job and
          ((has("workflow_name") | not) or
           ((.workflow_name | type) == "string" and
            .workflow_name == $workflow_name)) and
          ((has("workflow_id") | not) or
           ((.workflow_id | type) == "number" and
            .workflow_id == ($workflow_id | tonumber))) and
          .run_id == ($run_id | tonumber) and
          (.head_sha | type == "string") and
          .head_sha == $run_sha and
          ((has("head_repository") | not) or
           (.head_repository == null or
            ((.head_repository | type) == "object" and
             .head_repository.full_name == $head_repo and
             .head_repository.id == $head_repo_id))) and
          any(.steps[]?;
            .name == $generation_step and
            .status == "completed"
          )
       )] | length' <<<"${all_jobs_json}")"; then
    fail "Could not validate CLA Assistant v3 generation anchor"
  fi
  [[ "${assistant_count}" =~ ^[0-9]+$ && "${assistant_failed_count}" =~ ^[0-9]+$ &&
     "${assistant_success_count}" =~ ^[0-9]+$ && "${assistant_valid_count}" =~ ^[0-9]+$ ]] ||
    fail "Could not count CLA Assistant v3 jobs"
  (( assistant_count == 1 )) || fail "Expected exactly one CLA Assistant v3 generation anchor"
  (( assistant_valid_count == 1 )) || fail "The selected failed CLA check was created by an older workflow generation. Push a new commit or close and reopen this pull request to create a current-generation CLA check, then post the exact signing declaration again."
  (( assistant_failed_count <= 1 )) || fail "The selected CLA run contains multiple failed CLA Assistant v3 jobs"
  if (( assistant_failed_count == 0 && assistant_success_count != 1 )); then
    fail "The CLA Assistant v3 generation anchor did not complete successfully"
  fi

  if ! writer_count="$(jq -r \
      --arg writer_job "${CLA_WRITER_JOB}" \
      '[.[] | select(.name == $writer_job)] | length' <<<"${failed_jobs_json}")" ||
     ! writer_valid_count="$(jq -r \
       --arg run_id "${run_id}" \
       --arg run_sha "${run_execution_sha}" \
       --arg head_repo "${head_repo}" \
       --argjson head_repo_id "${head_repo_id}" \
       --arg writer_job "${CLA_WRITER_JOB}" \
       --arg workflow_name "${CLA_WORKFLOW_NAME}" \
       --arg workflow_id "${workflow_id}" \
       '[.[] | select(
          .name == $writer_job and
          ((has("workflow_name") | not) or
           ((.workflow_name | type) == "string" and
            .workflow_name == $workflow_name)) and
          ((has("workflow_id") | not) or
           ((.workflow_id | type) == "number" and
            .workflow_id == ($workflow_id | tonumber))) and
          .run_id == ($run_id | tonumber) and
          (.head_sha | type == "string") and
          .head_sha == $run_sha and
          ((has("head_repository") | not) or
           (.head_repository == null or
            ((.head_repository | type) == "object" and
             .head_repository.full_name == $head_repo and
             .head_repository.id == $head_repo_id)))
       )] | length' <<<"${failed_jobs_json}")"; then
    fail "Could not validate failed CLA ledger writer jobs"
  fi
  [[ "${writer_count}" =~ ^[0-9]+$ && "${writer_valid_count}" =~ ^[0-9]+$ ]] || fail "Could not count failed CLA ledger writer jobs"
  (( writer_count <= 1 )) || fail "The selected CLA run contains multiple failed CLA ledger writer jobs"
  (( writer_valid_count == writer_count )) || fail "The failed CLA ledger writer job is malformed or bound to a different source"

  compatibility_count="$(jq -r --arg compatibility_job "${CLA_COMPATIBILITY_JOB}" '[.[] | select(.name == $compatibility_job)] | length' <<<"${failed_jobs_json}")"
  if ! compatibility_valid_count="$(jq -r \
      --arg run_id "${run_id}" \
      --arg run_sha "${run_execution_sha}" \
      --arg head_repo "${head_repo}" \
      --argjson head_repo_id "${head_repo_id}" \
      --arg compatibility_job "${CLA_COMPATIBILITY_JOB}" \
      --arg workflow_name "${CLA_WORKFLOW_NAME}" \
      --arg workflow_id "${workflow_id}" \
      --arg compatibility_step "${CLA_COMPATIBILITY_STEP}" \
      '[.[] | select(
         .name == $compatibility_job and
         ((has("workflow_name") | not) or
          ((.workflow_name | type) == "string" and
           .workflow_name == $workflow_name)) and
         ((has("workflow_id") | not) or
          ((.workflow_id | type) == "number" and
           .workflow_id == ($workflow_id | tonumber))) and
         .run_id == ($run_id | tonumber) and
         (.head_sha | type == "string") and
         .head_sha == $run_sha and
         ((has("head_repository") | not) or
          (.head_repository == null or
           ((.head_repository | type) == "object" and
            .head_repository.full_name == $head_repo and
            .head_repository.id == $head_repo_id)))
          and any(.steps[]?;
            .name == $compatibility_step and
            .status == "completed"
          )
       )] | length' <<<"${failed_jobs_json}")"; then
    fail "Could not validate failed CLA compatibility jobs"
  fi
  [[ "${compatibility_count}" =~ ^[0-9]+$ && "${compatibility_valid_count}" =~ ^[0-9]+$ ]] || fail "Could not count failed CLA compatibility jobs"
  (( compatibility_count <= 1 )) || fail "The selected CLA run contains multiple failed compatibility jobs"
  (( compatibility_valid_count == compatibility_count )) || fail "The failed CLA compatibility job is malformed or bound to a different source"
  if (( assistant_failed_count == 1 )); then
    RERUN_TARGET_JOB_NAME="${CLA_ASSISTANT_JOB}"
  elif (( compatibility_count == 1 && writer_count == 0 )); then
    # A transient compatibility-mirror failure can block a repository that
    # still requires the legacy context during migration. The successful v3
    # job above remains the independently validated generation anchor.
    RERUN_TARGET_JOB_NAME="${CLA_COMPATIBILITY_JOB}"
  else
    fail "The selected CLA run has no eligible failed result job"
  fi
  if (( writer_count == 1 || compatibility_count == 1 )); then
    RERUN_FAILED_JOBS=true
  else
    RERUN_FAILED_JOBS=false
  fi
}
validate_failed_job_set "${jobs_json}"
# Select the sole failed result job from a validated job set. The v3 job
# carries the generation marker. A compatibility-only failure uses the
# separately validated successful v3 job as its generation anchor.
select_rerun_job() {
  local payload="$1"
  jq -c \
    --arg run_id "${run_id}" \
    --arg run_sha "${run_execution_sha}" \
    --arg target_job "${RERUN_TARGET_JOB_NAME}" \
    --arg assistant_job "${CLA_ASSISTANT_JOB}" \
    --arg compatibility_job "${CLA_COMPATIBILITY_JOB}" \
    --arg workflow_name "${CLA_WORKFLOW_NAME}" \
    --arg workflow_id "${workflow_id}" \
    --arg generation_step "CLA generation ${CLA_GENERATION}" \
    --arg compatibility_step "${CLA_COMPATIBILITY_STEP}" \
    --arg head_repo "${head_repo}" \
    --argjson head_repo_id "${head_repo_id}" \
    '[.[] | .jobs[]?
      | select(
          (.run_id | tostring) == $run_id and
          .name == $target_job and
          ((has("workflow_name") | not) or
           ((.workflow_name | type) == "string" and
            .workflow_name == $workflow_name)) and
          ((has("workflow_id") | not) or
           ((.workflow_id | type) == "number" and
            .workflow_id == ($workflow_id | tonumber))) and
          .status == "completed" and
          .conclusion == "failure" and
          (.head_sha | type == "string") and
          .head_sha == $run_sha and
          (
            .head_repository == null or
            (.head_repository.full_name == $head_repo and
             .head_repository.id == $head_repo_id)
          ) and
          (($target_job == $assistant_job and
            any(.steps[]?;
              .name == $generation_step and
              .status == "completed"
            )) or
           ($target_job == $compatibility_job and
            any(.steps[]?;
              .name == $compatibility_step and
              .status == "completed"
            )))
        )
    ]
    | if length == 1 then .[0] else empty end
  ' <<<"${payload}"
}

# Validate the exact failed result job for every discovery and final re-read.
validate_exact_job_payload() {
  local payload="$1"
  jq -e \
    --arg job_id "${job_id}" \
    --arg run_id "${run_id}" \
    --arg run_sha "${run_execution_sha}" \
    --arg target_job "${RERUN_TARGET_JOB_NAME}" \
    --arg assistant_job "${CLA_ASSISTANT_JOB}" \
    --arg compatibility_job "${CLA_COMPATIBILITY_JOB}" \
    --arg workflow_name "${CLA_WORKFLOW_NAME}" \
    --arg workflow_id "${workflow_id}" \
    --arg generation_step "CLA generation ${CLA_GENERATION}" \
    --arg compatibility_step "${CLA_COMPATIBILITY_STEP}" \
    --arg head_repo "${head_repo}" \
    --argjson head_repo_id "${head_repo_id}" '
      (.id | type == "number") and
      .id == ($job_id | tonumber) and
      (.run_id | type == "number") and
      .run_id == ($run_id | tonumber) and
      .name == $target_job and
      ((has("workflow_name") | not) or
       ((.workflow_name | type) == "string" and
        .workflow_name == $workflow_name)) and
      ((has("workflow_id") | not) or
       ((.workflow_id | type) == "number" and
        .workflow_id == ($workflow_id | tonumber))) and
      .status == "completed" and
      .conclusion == "failure" and
      (.head_sha | type == "string") and
      .head_sha == $run_sha and
      (
        (has("head_repository") | not) or
        .head_repository == null or
        ((.head_repository | type) == "object" and
         .head_repository.full_name == $head_repo and
         .head_repository.id == $head_repo_id)
      ) and
      (($target_job == $assistant_job and
        any(.steps[]?;
          .name == $generation_step and
          .status == "completed"
        )) or
       ($target_job == $compatibility_job and
        any(.steps[]?;
          .name == $compatibility_step and
          .status == "completed"
        )))
    ' <<<"${payload}" >/dev/null
}

target_job_name="${RERUN_TARGET_JOB_NAME}"
[[ -n "${target_job_name}" ]] || fail "The selected CLA run has no eligible failed result job"
if ! cla_job_json="$(select_rerun_job "${jobs_json}")"; then
  fail "Could not validate the selected CLA result job"
fi
if [[ -z "${cla_job_json}" ]]; then
  fail "The selected failed CLA result job is malformed or bound to an older workflow generation"
fi
job_id="$(jq -r '.id // empty' <<<"${cla_job_json}")"
[[ "${job_id}" =~ ^[1-9][0-9]*$ ]] || fail "The selected CLA job ID is invalid"
validate_failed_check_binding "${run_id}" "${job_id}" "${target_job_name}"

# Re-read the individual job. The jobs list is discovery only, just
# like the workflow-run list above.
job_json="$(gh_api_bounded "repos/${GH_REPO}/actions/jobs/${job_id}" 2>/dev/null)" || fail "Could not query the selected CLA result job"
validate_exact_job_payload "${job_json}" || fail "The selected CLA result job no longer matches the failed job in this run"

# Recheck both resources immediately before the state-changing call.
# This prevents a push or a concurrent rerun from making the job
# stale while the preceding API requests were in flight.
latest_pr_json="$(gh_api_bounded "repos/${GH_REPO}/pulls/${PR_NUMBER}" 2>/dev/null)" || fail "Could not recheck the pull request before rerun"
validate_exact_pr_snapshot "${latest_pr_json}" || fail "The pull request changed while selecting the CLA job"
final_job_json="$(gh_api_bounded "repos/${GH_REPO}/actions/jobs/${job_id}" 2>/dev/null)" || fail "Could not recheck the selected CLA job"
validate_exact_job_payload "${final_job_json}" || fail "The exact failed CLA result job is no longer eligible"

# Re-fetch the whole job set immediately before the state-changing call. This
# catches a newly cancelled or unrelated failed job that could otherwise be
# pulled into a failed-jobs rerun after the first validation.
final_jobs_json="$(fetch_jobs_for_run "${run_id}")" || fail "Could not recheck and validate jobs for the selected CLA run"
validate_failed_job_set "${final_jobs_json}"
[[ "${RERUN_TARGET_JOB_NAME}" == "${target_job_name}" ]] || fail "The failed CLA result job changed while preparing the rerun"
final_cla_job_json="$(select_rerun_job "${final_jobs_json}")" || fail "Could not select the final CLA result job"
final_job_id="$(jq -r '.id // empty' <<<"${final_cla_job_json}")"
[[ "${final_job_id}" == "${job_id}" ]] || fail "The selected CLA job changed while preparing the rerun"

# Re-read the live PR, run, and job as one final authorization set. A source
# push, branch retarget, job replacement, or concurrent rerun must invalidate
# the request before the state-changing call. For fallback runs, the failed
# check is fetched last and must bind both the exact source SHA and this job.
final_pr_json="$(gh_api_bounded "repos/${GH_REPO}/pulls/${PR_NUMBER}" 2>/dev/null)" || fail "Could not recheck the pull request before rerun"
validate_exact_pr_snapshot "${final_pr_json}" || fail "The pull request changed before rerun"
final_run_json="$(gh_api_bounded "repos/${GH_REPO}/actions/runs/${run_id}" 2>/dev/null)" || fail "Could not recheck the selected CLA run before rerun"
validate_exact_run_payload "${final_run_json}" || fail "The selected CLA run changed before rerun"
validate_run_source_binding "${final_run_json}"
final_job_json="$(gh_api_bounded "repos/${GH_REPO}/actions/jobs/${job_id}" 2>/dev/null)" || fail "Could not recheck the selected CLA job before rerun"
validate_exact_job_payload "${final_job_json}" || fail "The selected CLA job changed before rerun"
validate_failed_check_binding "${run_id}" "${job_id}" "${target_job_name}"

if [[ "${RERUN_FAILED_JOBS}" == true ]]; then
  rerun_endpoint="repos/${GH_REPO}/actions/runs/${run_id}/rerun-failed-jobs"
  rerun_description="failed CLA result jobs (writer, v3, and compatibility)"
else
  rerun_endpoint="repos/${GH_REPO}/actions/jobs/${job_id}/rerun"
  rerun_description="CLA job ${job_id}"
fi
if ! gh api \
  --method POST \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  "${rerun_endpoint}" >/dev/null 2>&1; then
  fail "Could not rerun the exact failed CLA job set"
fi
echo "Requested rerun for ${rerun_description} in workflow run ${run_id} at execution ${run_execution_sha} for PR head ${head_sha}"
