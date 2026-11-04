# What review keeps catching in cmux

> **Draft for Lawrence and Leo to prune.** Mined on 2026-10-18 from 5,618 PRs merged between
> 2026-09-20 and 2026-10-18 with `scripts/review-history.py`. A rule is here because review
> comments of that kind were followed by a fix commit on the PR, and the thread was then
> resolved or marked outdated. Delete anything that isn't worth a reviewer's attention, and add
> what the history can't see.

Read this before you open a PR and before you review one. Each section names the mistake, why it
matters, and a PR where review caught it. Repo-specific rules for the bot reviewers stay in
[`.github/review-bot-rules/`](.github/review-bot-rules/); this file is the short list that keeps
coming back.

**Where this comes from.** 4,664 review comments on 1,186 of those PRs led to a fix. Every one
came from a review bot: CodeRabbit 2,624, Cursor Bugbot 777, cubic 660, Greptile 588, Codex 15.
No human inline review comment was followed by a fix in this window. Human review here happens
in the merge gate and in conversation, not in review threads, so these rules describe what the
bots catch. To refresh the numbers:

```bash
scripts/review-history.py collect --since 2026-09-20 --cache review-history.jsonl
scripts/review-history.py cluster --cache review-history.jsonl > clusters.md
```

## 1. Tests that don't test the change (963 comments, the largest group)

- **Assert the behavior the PR adds, not that the code ran.** A test that only checks the exit
  code, or that the function returned, passes before the fix too. "The FreshState suite never
  verifies the deletion it was written to protect" (#16427). "These tests exercise only
  `attention_needed`; they never invoke `sync_attention_label`" (#13390).
- **The test must fail without the fix.** That is the red/green rule in [CLAUDE.md](CLAUDE.md#ci-review-and-merge).
  "This burst never creates a backlog, so it does not exercise what the change adds" (#16340).
- **No vacuous passes.** An assertion over an empty extraction, a loop over zero items, or a
  `contains` on an empty list passes for the wrong reason (#16460).
- **Isolate the test from the machine.** Give a CLI-spawning test its own `HOME` and
  `CFFIXED_USER_HOME`, its own defaults suite and its own temp dir, and don't read the real
  user's config (#10440, #14688, #13225).
- **Don't assert localized English.** Assert the key or the structured error, not the English
  text a locale can change (#14688).

## 2. Cancellation, stale results and races (555)

- **A result that arrives late must not overwrite a newer one.** Fence async work by a
  generation, task identity or revision, and drop results from a superseded request. "Superseded
  create failure clears newer select" (#19112). "Fence refresh-task cleanup by task identity"
  (#19977). "Rapid team selection" errors from an old switch (#13156).
- **Cancellation is a path, not an afterthought.** Decide what a cancelled create, attach or
  download leaves behind. "Closing a Cloud browser while `createBrowser` is in flight can leave a
  committed daemon tab" (#19032). "A bridge task remains alive after consumer cancellation"
  (#15797).
- **Check-then-act needs one owner.** Two callers can both see "no child" and both spawn one
  (#16174). Two writers can lock different sidecars unless the target is canonicalized first
  (#13254). Concurrent workflow runs for one PR overwrite each other's labels (#13390).

## 3. Edge cases: empty, nil, invalid, unbounded (512)

- **Reject empty, whitespace-only and malformed input where it enters**, not three calls later
  (#13632, #16448, #18838).
- **Bound everything a caller controls.** A `limit` passed straight to SQLite, a reply that copies
  the whole ancestor list, a listing with no cursor: each is a memory or latency cliff (#16430,
  #13358). Reads from a path given on the command line need a size cap enforced while reading
  (#13389).
- **Bash 3.2 and `set -u`:** guard empty array expansion (#13383).

## 4. Localization and user-facing text (315)

- **Every new user-facing string goes through the catalog with every supported locale filled
  in.** "Add translations for every catalog locale" is the single most repeated fix in the
  history (#13302, #15677, #16669, #20066 and dozens more). The
  [localization skill](skills/cmux-localization/SKILL.md) has the procedure.
- **No English copied into other locales as a placeholder** (#13300), and no hard-coded English in
  CLI usage text, JSX or alerts (#13389, #13319).
- **Read the translation as a speaker would.** Bots caught ungrammatical Italian, a wrong Arabic
  word and a misleading "6-digit code" claim (#16364, #16319).

## 5. Security: authorization, secrets and untrusted input (232)

- **Never interpolate untrusted values into a shell or `${{ }}` expression in a workflow.** Pass
  them through `env` (CWE-94, #13383).
- **Fail closed.** When a classifier, a probe or an authorization check can't run, refuse; don't
  waive (#21478, #9193). An error path that turns "can't check" into "allowed" is the bug.
- **Create private files in private directories** and check ownership before trusting a path
  (CWE-59, #13411). Validate a canonical root before deleting under it (#17207).
- **Remote relay and socket methods** follow [relay authorization](skills/cmux-socket-policy/references/remote-relay-authorization.md):
  a new method that isn't on the allowlist doesn't work remotely (#18222).

## 6. Fixed sleeps, timeouts and polling (228)

- **Wait for the signal, not the clock.** Replace `sleep N`, fixed yields and polling loops with a
  readiness signal, a completion callback or an explicit condition (#13351, #18457, #19617,
  #20441). This is the most common test-flake fix. In production code it's a correctness bug.
  See [`runtime-no-hacky-sleeps`](.github/review-bot-rules/runtime-no-hacky-sleeps.md).
- **A timeout must stop the work.** "Make the child timeout terminate the process" (#15001).
  Killing git with SIGKILL mid-write leaves a broken repo (#16094).
- **Match the client and server budgets** (#18962, #16428).

## 7. CI, workflows and scripts (215)

- **A new lint or test that no CI job runs doesn't exist** (#11264). Wire it and show it running.
- **`workflow_run` fires only from the default branch** (#18896), and some jobs run the base
  branch's copy of a script rather than the PR's (#18244). Check which copy actually runs.
- **Keep executable bits** on scripts that workflows invoke directly (#13393).
- **A PR that only edits a workflow must still run that workflow's checks**; the change
  classifier once routed such a PR to nothing (#13382).

## 8. State ownership and one source of truth (133)

- **Derive from the owner, not a global.** "The new workspace host is derived from the app-global
  selected workspace rather than the sidebar's owning window" (#13155). Two stores for one value
  diverge (#13156). See [`reliability-single-source-of-truth`](.github/review-bot-rules/reliability-single-source-of-truth.md)
  and [`no-ambient-global-state`](.github/review-bot-rules/no-ambient-global-state.md).
- **No test seams or debug-only properties in production source** (#14958, #16638).

## 9. Errors swallowed or reported as success (126)

- **Don't report success after dropping input.** An import that skips unreadable records, an
  overflow that discards silently, or a fork that says "done" before the tab exists all hide data
  loss (#16174, #12105, #17615).
- **Fire-and-forget promises need a `catch`** that the user can see (#13156, #17615).
- **Scripts exit nonzero on failure.** A nonempty output file isn't success when the producer
  exited nonzero (#16427, #21302).

## 10. Cleanup and lifetimes (108)

- **Every create has a matching teardown on every path**, including the failure and cancel
  paths: temp files and directories, remote tabs, receipts, DispatchSources (#16428, #13319,
  #13202, #17243).
- **Prefer `weak` references to stored identifiers** that outlive their object (#16352).

## 11. Main thread and actor isolation (96)

- **Pure value types shouldn't inherit `@MainActor`** under Swift 6 defaults; mark them
  `nonisolated` (#13295, #13219, #13155).
- **Don't do whole-snapshot work on every keystroke on the main actor.** Debounce, or diff by
  fingerprint (#13429). See [`hot-path-allocating-formatting`](.github/review-bot-rules/hot-path-allocating-formatting.md).
- **`assumeIsolated` traps** when a callback can arrive on the main thread outside the actor,
  for example KVO (#15445).

## Smaller groups

- **Docs and comments out of date (64):** when you change a contract, update the prose next to it
  in the same PR (#13146, #16430).
- **Dead code and duplication (61):** remove the API your change made unreachable (#16350,
  #12607), and share constants instead of syncing them by comment (#16427).
- **Performance (20):** no full rescans or `String(format:)` per row, and no quadratic lookups
  (#15748, #15744, #19096).

About a fifth of addressed comments (1,032) fit no group here; they're one-off logic bugs. Run
the clusterer and read its "Unmatched" list for new themes before adding a section.
