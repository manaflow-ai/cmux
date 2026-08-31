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
[[ "${COMMENT_AUTHOR_ID}" =~ ^[1-9][0-9]*$ ]] || fail "Comment author ID is invalid"
[[ -n "${COMMENT_AUTHOR_LOGIN}" ]] || fail "Comment author is missing"
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
[[ "${CLA_GENERATION}" =~ ^v[0-9]+\.[0-9]+-action-[0-9a-f]{7,40}$ ]] || fail "Invalid CLA generation marker"

issue_json="$(gh api "repos/${GH_REPO}/issues/${PR_NUMBER}" 2>/dev/null)" || fail "Could not query the issue"
issue_state="$(jq -r '.state // empty' <<<"${issue_json}")"
issue_pr_url="$(jq -r '.pull_request.url // empty' <<<"${issue_json}")"
[[ "${issue_state}" == "open" ]] || fail "The issue is not an open pull request"
[[ "${issue_pr_url}" == "https://api.github.com/repos/${GH_REPO}/pulls/${PR_NUMBER}" ]] || fail "The issue is not the exact repository pull request"

pr_json="$(gh api "repos/${GH_REPO}/pulls/${PR_NUMBER}" 2>/dev/null)" || fail "Could not query the pull request"
jq -e --arg repo "${GH_REPO}" --argjson number "${PR_NUMBER}" --arg base "${TARGET_BASE_REF}" '
  .number == $number and
  .state == "open" and
  .base.ref == $base and
  (.base.repo.id | type == "number") and
  .base.repo.full_name == $repo and
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
repo_id="$(jq -r '.base.repo.id // empty' <<<"${pr_json}")"
pr_author_login="$(jq -r '.user.login // empty' <<<"${pr_json}")"
pr_author_id="$(jq -r '.user.id // empty' <<<"${pr_json}")"
[[ "${head_ref}" != "" && "${head_repo}" != "" ]] || fail "The pull request head repository is missing"
[[ "${head_repo_id}" =~ ^[1-9][0-9]*$ ]] || fail "The pull request head repository ID is missing"
[[ "${repo_id}" =~ ^[1-9][0-9]*$ ]] || fail "The pull request base repository ID is missing"
[[ "${pr_author_login}" != "" ]] || fail "The pull request author is missing"
[[ "${pr_author_id}" =~ ^[1-9][0-9]*$ ]] || fail "The pull request author ID is missing"
# A contributor may recheck their own pull request. A different
# commenter must be a trusted repository participant, which limits
# unauthenticated users to the harmless no-op path.
if [[ "${COMMENT_BODY}" == "recheck" && "${COMMENT_AUTHOR_ID}" != "${pr_author_id}" ]]; then
  case "${COMMENT_AUTHOR_ASSOCIATION}" in
    OWNER|MEMBER|COLLABORATOR) ;;
    *) fail "Only the pull request author or a trusted repository participant may request a CLA rerun" ;;
  esac
fi

# The workflow-run list can omit pull_requests for
# pull_request_target runs. Resolve the commit through GitHub's PR
# association endpoint when GitHub has the commit in the base repo.
# Fork-only commits can legitimately return an empty list, so the
# exact live PR plus the run head_repository binding below is the
# association proof in that case.
commit_prs_json="$(gh api \
  --method GET \
  --header 'Accept: application/vnd.github+json' \
  --raw-field per_page=100 \
  --raw-field page=1 \
  "repos/${GH_REPO}/commits/${head_sha}/pulls" 2>/dev/null)" || fail "Could not query pull request associations"
jq -e 'type == "array"' <<<"${commit_prs_json}" >/dev/null || fail "Could not validate pull request associations"
association_count="$(jq -r 'length' <<<"${commit_prs_json}")"
[[ "${association_count}" =~ ^[0-9]+$ ]] || fail "Could not count pull request associations"
(( association_count < 100 )) || fail "Too many pull request associations for this head; ask an administrator to resolve the association before requesting a rerun"
if (( association_count > 0 )); then
  jq -e \
    --arg repo "${GH_REPO}" \
    --arg pr "${PR_NUMBER}" \
    --arg sha "${head_sha}" \
    --arg base "${TARGET_BASE_REF}" \
    --arg head_ref "${head_ref}" \
    --argjson head_repo_id "${head_repo_id}" '
      any(.[]?;
        (.number | tostring) == $pr and
        .base.ref == $base and
        .base.repo.full_name == $repo and
        .head.ref == $head_ref and
        .head.sha == $sha and
        (.head.repo.id | type == "number") and
        .head.repo.id == $head_repo_id
      )
    ' <<<"${commit_prs_json}" >/dev/null || fail "The current head is not associated with this pull request"
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
  open_prs_page="$(gh api \
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
  (( open_pr_count < 100 )) || fail "Too many open pull requests share this head; push a new head or ask an administrator to resolve the association before requesting a rerun"
  open_prs_json="$(jq -c '[.]' <<<"${open_prs_page}")"
  if ! matching_open_prs_json="$(jq -c \
      --arg repo "${GH_REPO}" \
      --arg sha "${head_sha}" \
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

workflow_page="$(gh api \
  --method GET \
  --header 'Accept: application/vnd.github+json' \
  --raw-field per_page=100 \
  --raw-field page=1 \
  "repos/${GH_REPO}/actions/workflows" 2>/dev/null)" || fail "Could not query repository workflows"
jq -e 'type == "object" and (.workflows | type == "array")' <<<"${workflow_page}" >/dev/null || fail "Could not validate repository workflows"
workflow_count="$(jq -r '.workflows | length' <<<"${workflow_page}")"
[[ "${workflow_count}" =~ ^[0-9]+$ ]] || fail "Could not count repository workflows"
(( workflow_count < 100 )) || fail "Too many active repository workflows; ask an administrator to reduce the workflow list before requesting a rerun"
workflow_json="$(jq -c '[.]' <<<"${workflow_page}")"
workflow_id="$(jq -r --arg path "${WORKFLOW_PATH}" '[.[] | .workflows[]? | select(.path == $path and .state == "active") | .id] | if length == 1 then .[0] else empty end' <<<"${workflow_json}")"
[[ "${workflow_id}" =~ ^[1-9][0-9]*$ ]] || fail "The expected CLA workflow is not active"

# Search a bounded first page, then choose the newest completed
# failure created no later than this comment. Edited, reopened, and
# synchronize events can leave several eligible failures for one
# exact head, so sort by creation time and run ID and select the
# newest one. Every candidate is tied to the exact workflow path,
# event, and PR association. When GitHub includes pull_requests on a
# run, bind the candidate to the exact PR object, including its
# source head SHA.
# GitHub can return an empty array for fork pull_request_target runs,
# so those candidates use the unique live open-PR association checked
# above and the exact run head-repository binding below. The run's
# head_sha is retained as an execution identity and is not assumed to
# equal the source PR SHA.
runs_page="$(gh api \
  --method GET \
  --header 'Accept: application/vnd.github+json' \
  --raw-field event="${TARGET_EVENT}" \
  --raw-field per_page=100 \
  --raw-field page=1 \
  "repos/${GH_REPO}/actions/workflows/${workflow_id}/runs" 2>/dev/null)" || fail "Could not query CLA workflow runs"
jq -e 'type == "object" and (.workflow_runs | type == "array")' <<<"${runs_page}" >/dev/null || fail "Could not validate CLA workflow runs"
run_count="$(jq -r '.workflow_runs | length' <<<"${runs_page}")"
[[ "${run_count}" =~ ^[0-9]+$ ]] || fail "Could not count CLA workflow runs"
(( run_count < 100 )) || fail "Too many CLA workflow runs to inspect safely; push a new commit or ask an administrator to prune old runs before requesting a rerun"
runs_json="$(jq -c '[.]' <<<"${runs_page}")"
if ! candidate_list_json="$(jq -c \
    --arg path "${WORKFLOW_PATH}" \
    --arg event "${TARGET_EVENT}" \
    --arg sha "${head_sha}" \
    --arg workflow_id "${workflow_id}" \
    --arg pr "${PR_NUMBER}" \
    --arg repo "${GH_REPO}" \
    --arg head_repo "${head_repo}" \
    --argjson head_repo_id "${head_repo_id}" \
    --argjson repo_id "${repo_id}" \
    --arg base "${TARGET_BASE_REF}" \
    --arg head_ref "${head_ref}" \
    --arg before "${COMMENT_CREATED_AT}" '
      def run_binds_to_pr:
        (.pull_requests) as $raw_prs
        | (if $raw_prs == null then []
           elif ($raw_prs | type) == "array" then $raw_prs
           else null end) as $prs
        | if $prs == null then false
          elif ($prs | length) == 0 then
            .head_branch == $head_ref and
            (
              ((.head_repository | type) == "object" and
               .head_repository.full_name == $head_repo and
               (.head_repository.id | type == "number") and
               .head_repository.id == $head_repo_id) or
              (.head_repository == null and
               $head_repo == $repo and
               $head_repo_id == $repo_id)
            )
            # The source-commit association is checked again after
            # selecting the run when its execution SHA differs.
            # Keep the candidate discoverable so a valid GitHub
            # association can prove that execution identity.
          else any($prs[]?;
            (.number | type == "number") and
            (.number | tostring) == $pr and
            .base.ref == $base and
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
            (.path == $path or
            ((.path | startswith($path + "@")) and
             ((.path | length) > (($path | length) + 1)))) and
            .event == $event and
            (.workflow_id | type == "number") and
            .workflow_id == ($workflow_id | tonumber) and
            (.head_sha | type == "string") and
            (.head_sha | test("^[0-9a-f]{40}$")) and
            (.id | type == "number") and
            .id > 0 and
            .status == "completed" and
            .conclusion == "failure" and
            (.created_at | type == "string") and
            .created_at <= $before and
            run_binds_to_pr
          )
      ]
      | sort_by([.created_at, .id])
    ' <<<"${runs_json}")"; then
  fail "Could not validate CLA workflow run data"
fi
candidate_count="$(jq -r 'length' <<<"${candidate_list_json}")"
[[ "${candidate_count}" =~ ^[0-9]+$ ]] || fail "Could not count matching CLA workflow runs"
if [[ "${candidate_count}" == "0" ]]; then
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
    --arg before "${COMMENT_CREATED_AT}" \
    'def run_binds_to_pr:
       (.pull_requests) as $raw_prs
       | (if $raw_prs == null then []
          elif ($raw_prs | type) == "array" then $raw_prs
          else null end) as $prs
       | if $prs == null then false
         elif ($prs | length) == 0 then
           .head_branch == $head_ref and
           (
             ((.head_repository | type) == "object" and
              .head_repository.full_name == $head_repo and
              (.head_repository.id | type == "number") and
              .head_repository.id == $head_repo_id) or
             (.head_repository == null and
              $head_repo == $repo and
              $head_repo_id == $repo_id)
           )
         else any($prs[]?;
           (.number | type == "number") and
           (.number | tostring) == $pr and
           .base.ref == $base and
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
          (.path == $path or
          ((.path | startswith($path + "@")) and
            ((.path | length) > (($path | length) + 1)))) and
          .event == $event and
          (.workflow_id | type == "number") and
          .workflow_id == ($workflow_id | tonumber) and
          (.head_sha | type == "string") and
          (.head_sha | test("^[0-9a-f]{40}$")) and
          (.id | type == "number") and
          .id > 0 and
          .status == "completed" and
          .conclusion == "failure" and
          (.created_at | type == "string") and
          .created_at <= $before and
          run_binds_to_pr
        )
    ] | length' <<<"${runs_json}")"
  [[ "${stale_run_count}" =~ ^[0-9]+$ ]] || fail "Could not count stale CLA workflow runs"
  if (( stale_run_count > 0 )); then
    fail "The failed CLA check was created by an older workflow generation. Push a new commit or close and reopen this pull request to create a current-generation CLA check, then post the exact signing declaration again."
  fi
  # A valid signature can arrive after the check already passed.
  # Preserve the action's historical no-op behavior in that case.
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

# A run with a populated pull_requests array already carries an
# authenticated source-PR association. Some GitHub API responses
# omit that array, so prove a differing execution SHA through the
# commit association endpoint before allowing the fallback. A bare
# branch/repository match is not enough because a branch can be
# reused after a push.
validate_run_source_binding() {
  local run_payload="$1"
  local execution_sha pull_requests_type pull_request_count
  local execution_prs_json execution_association_count
  execution_sha="$(jq -r '.head_sha // empty' <<<"${run_payload}")"
  [[ "${execution_sha}" =~ ^[0-9a-f]{40}$ ]] || fail "The workflow run execution SHA is invalid"
  pull_requests_type="$(jq -r 'if .pull_requests == null then "null" else (.pull_requests | type) end' <<<"${run_payload}")"
  case "${pull_requests_type}" in
    null) pull_request_count=0 ;;
    array) pull_request_count="$(jq -r '.pull_requests | length' <<<"${run_payload}")" ;;
    *) fail "The workflow run pull request association is malformed" ;;
  esac
  [[ "${pull_request_count}" =~ ^[0-9]+$ ]] || fail "The workflow run pull request association count is invalid"
  (( pull_request_count == 0 )) || return 0
  [[ "${execution_sha}" == "${head_sha}" ]] && return 0

  execution_prs_json="$(gh api \
    --method GET \
    --header 'Accept: application/vnd.github+json' \
    --raw-field per_page=100 \
    --raw-field page=1 \
    "repos/${GH_REPO}/commits/${execution_sha}/pulls" 2>/dev/null)" || fail "Could not query workflow execution pull request associations"
  execution_association_count="$(jq -r 'if type == "array" then length else -1 end' <<<"${execution_prs_json}")"
  [[ "${execution_association_count}" =~ ^[0-9]+$ ]] || fail "Could not validate workflow execution pull request associations"
  (( execution_association_count < 100 )) || fail "Too many pull request associations for the workflow execution head; ask an administrator to resolve the association before requesting a rerun"
  jq -e \
    --arg repo "${GH_REPO}" \
    --arg pr "${PR_NUMBER}" \
    --arg execution_sha "${execution_sha}" \
    --arg base "${TARGET_BASE_REF}" \
    --arg head_ref "${head_ref}" \
    --arg head_repo "${head_repo}" \
    --argjson head_repo_id "${head_repo_id}" \
    --argjson repo_id "${repo_id}" '
      type == "array" and
      any(.[]?;
        (.number | type == "number") and
        (.number | tostring) == $pr and
        .base.ref == $base and
        .base.repo.full_name == $repo and
        (.base.repo.id | type == "number") and
        .base.repo.id == $repo_id and
        .head.ref == $head_ref and
        .head.sha == $execution_sha and
        (.head.repo.id | type == "number") and
        .head.repo.id == $head_repo_id and
        .head.repo.full_name == $head_repo
      )
    ' <<<"${execution_prs_json}" >/dev/null || fail "The workflow execution SHA is not associated with the current pull request"
}

# Re-read the individual run. The list response is only a discovery
# result, not authorization to rerun it.
run_json="$(gh api "repos/${GH_REPO}/actions/runs/${run_id}" 2>/dev/null)" || fail "Could not query the selected CLA run"
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
  --arg base "${TARGET_BASE_REF}" \
  --arg before "${COMMENT_CREATED_AT}" '
    def run_binds_to_pr:
      (.pull_requests) as $raw_prs
      | (if $raw_prs == null then []
         elif ($raw_prs | type) == "array" then $raw_prs
         else null end) as $prs
      | if $prs == null then false
        elif ($prs | length) == 0 then
          .head_branch == $head_ref and
          (
            ((.head_repository | type) == "object" and
             .head_repository.full_name == $head_repo and
             (.head_repository.id | type == "number") and
             .head_repository.id == $head_repo_id) or
            (.head_repository == null and
             $head_repo == $repo and
             $head_repo_id == $repo_id)
          )
        else any($prs[]?;
          (.number | type == "number") and
          (.number | tostring) == $pr and
          .base.ref == $base and
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
    .id == ($run_id | tonumber) and
    .workflow_id == ($workflow_id | tonumber) and
    (.path == $path or
     ((.path | startswith($path + "@")) and
      ((.path | length) > (($path | length) + 1)))) and
    .event == $event and
    .status == "completed" and
    .conclusion == "failure" and
    .head_sha == $run_sha and
    .head_branch == $run_head_branch and
    (.created_at | type == "string") and
    .created_at <= $before and
    run_binds_to_pr
  ' <<<"${run_json}" >/dev/null || fail "The selected run no longer matches the exact failed CLA check"
validate_run_source_binding "${run_json}"

# Close the main TOCTOU window. A push, close, or another rerun can
# happen while the API calls above run. Never rerun a stale head.
latest_pr_json="$(gh api "repos/${GH_REPO}/pulls/${PR_NUMBER}" 2>/dev/null)" || fail "Could not recheck the pull request"
jq -e --arg repo "${GH_REPO}" --argjson number "${PR_NUMBER}" --arg sha "${head_sha}" --arg base "${TARGET_BASE_REF}" --arg head_ref "${head_ref}" --arg head_repo "${head_repo}" --argjson head_repo_id "${head_repo_id}" --argjson base_repo_id "${repo_id}" --arg opener "${pr_author_login}" '
  .number == $number and
  .state == "open" and
  .base.ref == $base and
  .base.repo.full_name == $repo and
  .base.repo.id == $base_repo_id and
  .head.sha == $sha and
  .head.ref == $head_ref and
  .head.repo.full_name == $head_repo and
  .head.repo.id == $head_repo_id and
  .user.login == $opener
' <<<"${latest_pr_json}" >/dev/null || fail "The pull request changed while selecting the CLA run"

# Ensure another queued invocation did not already rerun this run.
final_run_json="$(gh api "repos/${GH_REPO}/actions/runs/${run_id}" 2>/dev/null)" || fail "Could not recheck the selected CLA run"
jq -e \
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
  --arg run_id "${run_id}" \
  --arg base "${TARGET_BASE_REF}" \
  --arg before "${COMMENT_CREATED_AT}" '
    def run_binds_to_pr:
      (.pull_requests) as $raw_prs
      | (if $raw_prs == null then []
         elif ($raw_prs | type) == "array" then $raw_prs
         else null end) as $prs
      | if $prs == null then false
        elif ($prs | length) == 0 then
          .head_branch == $head_ref and
          (
            ((.head_repository | type) == "object" and
             .head_repository.full_name == $head_repo and
             (.head_repository.id | type == "number") and
             .head_repository.id == $head_repo_id) or
            (.head_repository == null and
             $head_repo == $repo and
             $head_repo_id == $repo_id)
          )
        else any($prs[]?;
          (.number | type == "number") and
          (.number | tostring) == $pr and
          .base.ref == $base and
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
    .id == ($run_id | tonumber) and
    .workflow_id == ($workflow_id | tonumber) and
    (.path == $path or
     ((.path | startswith($path + "@")) and
      ((.path | length) > (($path | length) + 1)))) and
    .event == $event and
    .status == "completed" and
    .conclusion == "failure" and
    .head_sha == $run_sha and
    .head_branch == $run_head_branch and
    (.created_at | type == "string") and
    .created_at <= $before and
    run_binds_to_pr
' <<<"${final_run_json}" >/dev/null || fail "The exact failed CLA run is no longer eligible"
validate_run_source_binding "${final_run_json}"

# Rerun only the failed CLA job, rather than every job in the run.
# The job endpoint still requires actions:write, but it cannot
# accidentally restart an unrelated job added to this workflow.
jobs_page="$(gh api \
  --method GET \
  --header 'Accept: application/vnd.github+json' \
  --raw-field per_page=100 \
  --raw-field page=1 \
  "repos/${GH_REPO}/actions/runs/${run_id}/jobs" 2>/dev/null)" || fail "Could not query jobs for the selected CLA run"
jq -e 'type == "object" and (.jobs | type == "array")' <<<"${jobs_page}" >/dev/null || fail "Could not validate jobs for the selected CLA run"
job_count="$(jq -r '.jobs | length' <<<"${jobs_page}")"
[[ "${job_count}" =~ ^[0-9]+$ ]] || fail "Could not count jobs for the selected CLA run"
(( job_count < 100 )) || fail "Too many jobs in the selected CLA run; ask an administrator to inspect it before requesting a rerun"
jobs_json="$(jq -c '[.]' <<<"${jobs_page}")"
if ! cla_job_json="$(jq -c \
    --arg run_id "${run_id}" \
    --arg run_sha "${run_execution_sha}" \
    --arg cla_generation "${CLA_GENERATION}" \
    --arg run_head_branch "${run_head_branch}" \
    --arg head_repo "${head_repo}" \
    --argjson head_repo_id "${head_repo_id}" \
    '[.[] | .jobs[]?
      | select(
          (.run_id | tostring) == $run_id and
          .name == "CLA Assistant v2" and
          .workflow_name == "CLA Assistant v2" and
          .status == "completed" and
          .conclusion == "failure" and
          .head_sha == $run_sha and
          .head_branch == $run_head_branch and
          (
            .head_repository == null or
            (.head_repository.full_name == $head_repo and
             .head_repository.id == $head_repo_id)
          ) and
          any(.steps[]?;
            .name == ("CLA generation " + $cla_generation) and
            .status == "completed" and
            .conclusion == "success"
          )
        )
    ]
    | if length == 1 then .[0] else empty end
  ' <<<"${jobs_json}")"; then
  fail "Could not validate CLA job data"
fi
if [[ -z "${cla_job_json}" ]]; then
  # The run matched the current PR and failed, but no job carried
  # this workflow generation marker. It is an old or malformed
  # generation and must not be replayed with the privileged token.
  fail "The selected failed CLA check was created by an older workflow generation. Push a new commit or close and reopen this pull request to create a current-generation CLA check, then post the exact signing declaration again."
fi
job_id="$(jq -r '.id // empty' <<<"${cla_job_json}")"
[[ "${job_id}" =~ ^[1-9][0-9]*$ ]] || fail "The selected CLA job ID is invalid"

# Re-read the individual job. The jobs list is discovery only, just
# like the workflow-run list above.
job_json="$(gh api "repos/${GH_REPO}/actions/jobs/${job_id}" 2>/dev/null)" || fail "Could not query the selected CLA job"
jq -e \
  --arg job_id "${job_id}" \
  --arg run_id "${run_id}" \
  --arg run_sha "${run_execution_sha}" \
  --arg cla_generation "${CLA_GENERATION}" \
  --arg run_head_branch "${run_head_branch}" \
  --arg head_repo "${head_repo}" \
  --argjson head_repo_id "${head_repo_id}" '
    .id == ($job_id | tonumber) and
    .run_id == ($run_id | tonumber) and
    .name == "CLA Assistant v2" and
    .workflow_name == "CLA Assistant v2" and
    .status == "completed" and
    .conclusion == "failure" and
    .head_sha == $run_sha and
    .head_branch == $run_head_branch and
    (
      .head_repository == null or
      (.head_repository.full_name == $head_repo and
       .head_repository.id == $head_repo_id)
    ) and
    any(.steps[]?;
      .name == ("CLA generation " + $cla_generation) and
      .status == "completed" and
      .conclusion == "success"
    )
  ' <<<"${job_json}" >/dev/null || fail "The selected CLA job no longer matches the failed job in this run"

# Recheck both resources immediately before the state-changing call.
# This prevents a push or a concurrent rerun from making the job
# stale while the preceding API requests were in flight.
latest_pr_json="$(gh api "repos/${GH_REPO}/pulls/${PR_NUMBER}" 2>/dev/null)" || fail "Could not recheck the pull request before rerun"
jq -e --arg repo "${GH_REPO}" --argjson number "${PR_NUMBER}" --arg sha "${head_sha}" --arg base "${TARGET_BASE_REF}" --arg head_ref "${head_ref}" --arg head_repo "${head_repo}" --argjson head_repo_id "${head_repo_id}" --argjson base_repo_id "${repo_id}" --arg opener "${pr_author_login}" '
  .number == $number and
  .state == "open" and
  .base.ref == $base and
  .base.repo.full_name == $repo and
  .base.repo.id == $base_repo_id and
  .head.sha == $sha and
  .head.ref == $head_ref and
  .head.repo.full_name == $head_repo and
  .head.repo.id == $head_repo_id and
  .user.login == $opener
' <<<"${latest_pr_json}" >/dev/null || fail "The pull request changed while selecting the CLA job"
final_job_json="$(gh api "repos/${GH_REPO}/actions/jobs/${job_id}" 2>/dev/null)" || fail "Could not recheck the selected CLA job"
jq -e \
  --arg job_id "${job_id}" \
  --arg run_id "${run_id}" \
  --arg run_sha "${run_execution_sha}" \
  --arg cla_generation "${CLA_GENERATION}" \
  --arg run_head_branch "${run_head_branch}" \
  --arg head_repo "${head_repo}" \
  --argjson head_repo_id "${head_repo_id}" '
    .id == ($job_id | tonumber) and
    .run_id == ($run_id | tonumber) and
    .name == "CLA Assistant v2" and
    .workflow_name == "CLA Assistant v2" and
    .status == "completed" and
    .conclusion == "failure" and
    .head_sha == $run_sha and
    .head_branch == $run_head_branch and
    (
      .head_repository == null or
      (.head_repository.full_name == $head_repo and
       .head_repository.id == $head_repo_id)
    ) and
    any(.steps[]?;
      .name == ("CLA generation " + $cla_generation) and
      .status == "completed" and
      .conclusion == "success"
    )
  ' <<<"${final_job_json}" >/dev/null || fail "The exact failed CLA job is no longer eligible"

# Repeat the positive live-PR association check after all discovery
# calls. A second open PR for the same fork ref and SHA must stop the
# rerun even if it appeared while the earlier checks were running.
validate_live_open_head_association

if ! gh api \
  --method POST \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  "repos/${GH_REPO}/actions/jobs/${job_id}/rerun" >/dev/null 2>&1; then
  fail "Could not rerun the exact failed CLA job"
fi
echo "Requested rerun for CLA job ${job_id} in workflow run ${run_id} at execution ${run_execution_sha} for PR head ${head_sha}"
