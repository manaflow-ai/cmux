# cmux agent notes

Keep repo-wide decisions here; procedures belong in [CONTRIBUTING.md](CONTRIBUTING.md),
[area instructions](#area-instructions) and [task skills](skills/README.md).
Read the matching skill before changing an area, then only the references needed.

**Manaflow AI team members and their agents:** read the private [cmuxterm-hq CLAUDE.md](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/CLAUDE.md) and [AGENTS.md](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/AGENTS.md) before fleet or CI work. They are the entry point for fleet builds, CI routing, agent coordination, and landing rules. Start fleet work at [Fleet and CI: start here](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/build-fleet/FLEET-AND-CI.md). External contributors can ignore this block; those links return 404 for them.

## Verification and isolation

- Before committing, setup or a native build, [choose scoped verification](skills/cmux-testing/references/local-vs-ci-validation.md).
  Start with `python3 scripts/verify-local.py`; docs and portable tooling need no app build.
  Run repository commands only in a [trusted checkout](docs/contributor-verification.md#trust-boundary),
  including `verify-local.py --help`, `--list` and `--repo`. Push does not run checks for you.
- **Web lints before every commit and push.** A change to `webviews/` or `web/` runs
  `scripts/web-lint.sh` (the pre-push hook enforces it) and fixes every error; never push
  with a lint failure, because a base lint red skips the CI tests after it. Commands, skip
  reason and shared-host mode: [hooks and lints](skills/cmux-dev-workflow/references/hooks-and-lints.md).
- Use [CONTRIBUTING.md](CONTRIBUTING.md#getting-started) for setup. Tagged reloads default to
  `CMUX_DEV_BACKEND_MODE=local`; cmux-next needs no shared backend. Follow [tagged builds](skills/cmux-dev-workflow/references/tagged-builds.md)
  for commands and cache reuse; team fleet tasks start at
  [Fleet and CI: start here](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/build-fleet/FLEET-AND-CI.md).
  Never use bare `xcodebuild` or an untagged `cmux DEV.app`. Clean up only your own tags.
- **Agents never compile or test on the person's Mac.** No local `swift build`/`swift test`,
  `xcodebuild build|test`, `cargo build|test|clippy` or `scripts/reload.sh`: run them as a
  fleet step (`cmux-ci run --class CLASS --script ... --ref SHA`, `cmux-ci build cmux --ref SHA`).
  CLASS is the script's own class: `light` for Swift suites (`scripts/ci/package-test-lane.sh`,
  `run-swift-testing-suites.sh`), lints and the Rust check; `isolated` only for the scripts that
  say so. Any other class is refused with `runs as class X` and no step is made.
  Several agents' local SwiftPM test runs pegged the Mac at 100% CPU (2026-10-20). The PATH
  guards (`~/.local/lib/cmux-local-build-guards`) queue or refuse these; never bypass them.
- **Scope every search.** `rg`/`find`/`fd` only inside your worktree or a named subfolder, never
  `..`, `~`, `~/fun`, `/`, `$TMPDIR` or `/var/folders` (worktrees and caches there hold millions of
  files). Prefer `git grep` or `rg` with a path; prefix long scans with `nice -n 10`.
- A same-repo app PR gets a fleet dogfood build and link comment only while it has the
  `dev-build` label. Add it when someone will dogfood the PR, not by default; under load
  the fleet builds the newest push, and the comment says how to build a skipped commit.
- Never quit, kill, relaunch, replace or launch-profile the user's running cmux
  (`/Applications/cmux.app`, `com.cmuxterm.app`), including through a Release build or
  another bundle with that ID. Never set `CMUX_ALLOW_REPLACING_RUNNING_CMUX`; only the
  user may. Reproduce in a tagged build and attach profiling to its PID.
- Dogfood through `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh`, never `/tmp/cmux-cli`.
  Never report raw `.app` paths or `file://` URLs.
- The app package needs Swift tools 6.2 and deploys to macOS 14; the classic Swift 6.0 rule
  does not apply here. Check Release compiles and macOS 14 limits with
  [toolchain compatibility](skills/cmux-architecture/references/swift-6-0-compatibility.md).
- No fleet Mac runs macOS 14 or 15 (aws-m4pro-1..4 run 27, aws-m4pro-5..9 run 26). Check an
  OS-dependent bug or a launch on 14/15 in Tart VMs: `scripts/cmux-next/os-matrix.sh --build JOB
  --os 14,15` ([MATRIX.md](scripts/fuzz/macos-matrix/MATRIX.md)). VM timing is not perf evidence.

## cmux-next checks before every push

Before every push, run `python3 scripts/cmux-next/prepush-gate.py` (the pre-push hook runs it
too): a few seconds of static checks, no build, refusing only violations your commits add.
Swift/Rust builds and tests stay on the fleet. What it runs and how the hooks install:
[hooks and lints](skills/cmux-dev-workflow/references/hooks-and-lints.md).

- Never `--no-verify` and never `CMUX_NEXT_CHECKS_SKIP_REASON`, unless the failure is
  in files you did not touch. Then say so in your report, naming the check and the base sha.
  CI step "Pushed commits add no violations" names every commit that adds one.
- No blocking calls on the main thread: use the async or background API
  (`openInBackground`/`revealInBackground`, async reads, an injected `Clock`), not
  `Thread.sleep`, `.wait()`, `readDataToEndOfFile()`, `waitUntilExit()` or `NSWorkspace.shared.open`.
- No `try!`: throw or handle a typed error.
- Fonts come from `TypeScale` or `Typography`, never a literal size.
- Every animation goes through a category motion gate (`Motion.<category>.animate(...)` and
  friends) that obeys the master switch, the category switch, `ui.animationSpeed` and Reduce
  Motion; code works with no animation at all. No raw `NSAnimationContext`, `withAnimation`,
  `.animation(...)`, `CABasicAnimation` or `animator()` outside a gate, and no bypass of web
  `WebTheme`'s `data-cmux-motion`; a reviewed exception says `// motion: allow <how>`.
  `check-motion.sh` enforces it; categories and a new area's steps:
  [motion-DESIGN.md](plans/cmux-next/motion-DESIGN.md).
- Dialogs use the standard key-hint components (`CmuxDialogSpec`, `CmuxDialogActionButton`,
  `ThemedBezelButton.keyHint`, web `ui/DialogButton`), never `NSAlert`, `.alert` or `.confirmationDialog`.
- An escape comment (`// concurrency-allow:`, `// crash-allow:`, `dialog-keys-exempt:`)
  needs a reason that proves the code is safe; it is not a way to pass the gate.
- Never change a Ghostty-default shortcut without the user's explicit OK. Ghostty's split keys
  (Cmd-Opt-arrows focus a pane, Cmd-D / Cmd-Shift-D split, Ctrl-Cmd-arrows resize,
  Cmd-Shift-Return zoom) are reserved in `schemas/keybindings/ghostty-reserved-keys.json`;
  no other action may take one, in any pane. `GhosttyReservedKeysTests` and the gate's
  "Ghostty-default keys" check enforce it, and `CMUX_NEXT_CHECKS_SKIP_REASON` does not skip
  it: only a `Ghostty-defaults-OK: <the user's words>` commit trailer does. (2f3e1f95983 made
  Cmd-Opt-Left / Right sidebar keys; Lawrence 2026-10-20: "ensure this never happens again".)

- A new or rewritten action handler is `registry.bindEffect(id, effect:)` returning an
  `ActionEffect`; never await in a handler, start its remote work yourself, or do disk I/O, a
  waiting lock or a whole-session walk on its turn (< 10 ms to the commit; guardrail
  `action-wait`). Effect kinds and monitors: [zero-latency.md](plans/cmux-next/zero-latency.md),
  "Native actions: the budget contract".

### Retry a failed push

Push with `git push -q`: without `-q`, git spends 4-14 s printing a status for
all of GitHub's ~27,600 refs. `-q` still prints errors and the hook's output. The hook ends with
`pre-push: hook times: <each phase> Ns; total Ns`, which shows where a slow push spent its time.
- `pre-push: refused in <phase>` with a check's findings: fix them and push again. Do not retry unchanged.
- The gate's `ran past its <N>s limit` (600 s, more on a loaded Mac), a failure after `pre-push: passed`
  (`[remote rejected] ... (failed)`, `RPC failed`, `remote end hung up`, a timeout), or a
  `timeout 1500` kill: retry at most 3 times. Wait 30 s before the first retry, 60 s before
  the second and 120 s before the third.
- After each try, `git ls-remote origin refs/heads/<branch>` must equal `git rev-parse HEAD`.
  If it does, the push landed: stop.
- A failed push is never a reason for `--no-verify` or the git data API. After 3 failed retries,
  report the hook-times line and the last error.
- The hook takes a turn: 2 pushes are checked at once on a Mac (`CMUX_PREPUSH_SLOTS`), and the rest
  wait (`pre-push: ... waiting for a turn`; `queue Ns` in the hook-times line). A wait is not a hang.
- On a Mac too loaded to finish the hook (load average far above its core count), push through an
  idle Mac: `scripts/cmux-next/push-from-host.sh <branch>` pushes `HEAD` to `origin/<branch>` from
  `cmux-lawrence-2` (`--host`, `--sha`), where the same hook runs and refuses the same things.

## Before you touch hot paths

- Use the patterns in [PATTERNS.md](plans/cmux-next/PATTERNS.md) (composition root, seam adapters, targeted
  observation, instant create, main-thread budget, off-main frames, daemon request path) and meet
  [REVIEW-STANDARD.md](plans/cmux-next/REVIEW-STANDARD.md): root-cause fixes, no hacks, no partial fixes. Review
  landed work with the repo workflow `.claude/workflows/cmux-next-deep-review.js`.
- Budget: every action reaches its committed frame in < 10 ms p95; motion runs at full refresh, 0 drops.
  Measure on the fleet yourself, light and STRESS ([perf-lead.md](plans/cmux-next/perf-lead.md)), before and after.
- Never add CI gates, perf-gate rows or budgets, CI jobs or steps, or CI tests (Lawrence 2026-10-23: "not to
  add gates/tests in CI, but you have to run them yourself"). This rule is about CI only; it does not remove
  regression tests. Each fix still gets a regression test that fails without it; each agent runs its own
  regression tests itself on the fleet (cmux-ci, nx-remote) before and after the fix, and says the result in
  the commit. Do not move a test into CI to have it run for you.
- `// perf-hot: <budget> <path-id>` marks a per-frame, per-key or per-switch function; the pre-push hook names
  its bench ([perf-hot-benches.json](scripts/cmux-next/perf-hot-benches.json)). Mark new hot paths the same way.
- Read [OWNERS.md](plans/cmux-next/OWNERS.md) before you change an owned area, and tell the owner.
- Threads: [threading-model.md](plans/cmux-next/threading-model.md) says what each thread owns, may block on, its QoS and bound; the main thread never blocks (Debug detector, `allowBlocking` only for a listed reason).
- Copy Chrome's performance model (Lawrence 2026-10-24): before you design a fast path, find how
  Chromium does the same job and do that, or write in the commit why cmux differs. The main thread
  never blocks; input and changes coalesce to one frame per display refresh and animations are
  interruptible; measure input-to-frame as distributions, not means; hidden pages are discarded
  by Memory Saver rules and renderers shared per site; work runs by priority, and throttling is
  only for work the person cannot see, never the fix for a slow visible action.
- Go past Chrome where cmux is scripted: automation never competes with the person. Scripted
  changes use the same action pipeline at O(changed items); hidden workspaces update the model
  only; bursts coalesce to one model update and at most one frame per window; the person's input
  always goes first and the socket server works off the main thread.
  Full text of both rules: [PATTERNS.md](plans/cmux-next/PATTERNS.md#chrome-performance-model-lawrence-2026-10-24).
- The hook's guardrails refuse new debt in added lines (`scripts/cmux-next/guardrails.py --list`). When the
  hook warns that its installed copy is not origin/feat-cmux-next's, run `scripts/install-git-hooks.sh` from a
  checkout at origin/feat-cmux-next. The hooks are per clone: every worktree of it, main-based ones too, runs them.

## Crash classes

Each class of nightly crash has one guard. Do not work around it; fix the code.
- Unrecognized selector (a `super` call the framework class does not answer, a selector Chromium sends to
  NSApp): `scripts/cmux-next/check-objc-selectors.py` and `ObjCSelectorRuntimeTests` (runtime walk).
- AppKit off the main thread: suites run under Xcode's Main Thread Checker
  (`scripts/ci/run_swift_test_bundle.py`, `CMUX_MAIN_THREAD_CHECKER`, `MainThreadCheckerLoadedTests`).
- Stale AppKit index (-1 rows and columns): CmuxNextCompat's `clickedRowIfValid`, `selectedRowIfValid`,
  `clickedItemIfValid`, `item(ifValidRow:inColumn:)`; guardrails rule `appkit-index`.
- Undo into replaced text: set text from code only through `replaceAllTextUndoably(_:)` (CmuxNextDesign)
  in a view with `allowsUndo = true`; guardrails rule `undo-text-write`.
- Traps (`!`, `as!`, index, `fatalError`): `scripts/cmux-next/crash_ratchet.py`, whose baseline only goes down.
- Memory corruption and data races: run the suites of risky code under `CMUX_SWIFT_SANITIZE=address` or
  `thread` (`cmux-ci run --env CMUX_SWIFT_SANITIZE=...`); malloc zone changes: `malloc-zone-race/run.sh corrupt`.
- A crash that hangs: `CrashDeadline` (10 s) and the out-of-process `CrashWatcher` (15 s) end the app.

## Swift namespace convention

Public and package types in package source must expose an instance surface or
be scoped onto the owning type; caseless namespace enums and all-static public
or package types are lint violations. Run
`./scripts/lint-ios-package-conventions.sh --namespace-fix` before committing.
When installed with `scripts/install-git-hooks.sh --namespace-fix`, the
pre-push hook runs the fixer and stops so changed files can be reviewed,
staged, and committed. CI keeps the non-mutating lint as the backstop.

Post-edit and pre-commit hooks run the same fixer and format edited files the way CI checks
them, touching only those files ([hooks and lints](skills/cmux-dev-workflow/references/hooks-and-lints.md)).

## macOS and iOS parity

Every new feature or capability built on cmux-next macOS, however small or big, must also be
supported in the cmux-next iPhone app (`cmux-next-ios/`), with a row in
[cmux-next-ios/verify/parity-mac.md](cmux-next-ios/verify/parity-mac.md). Two exceptions, each
recorded there as "not from a phone" with its reason: Mac-only chrome (windows, menu bar, Dock),
and anything a paired phone may not do under [cmux-next-ios/SECURITY.md](cmux-next-ios/SECURITY.md)
and "Remote CLI relay" below. A phone path that needs a new trust or security policy goes to
https://github.com/manaflow-ai/cmux/issues/13742 with a recommendation first.

## Area instructions

Read these before working in their scope; nested files may not load automatically:

- `ios/` or `Packages/iOS/`: [ios/AGENTS.md](ios/AGENTS.md).
- Cloud backend code (control plane, VM API routes, provider drivers, billing,
  entitlements, the NEXT Worker): new code goes to the private
  manaflow-ai/cmux-platform repository, not here. Read
  [skills/cmux-backend/SKILL.md](skills/cmux-backend/SKILL.md) first.
- `web/` or any cmux Cloud database work: [web/AGENTS.md](web/AGENTS.md).
- `cmux-tui/`: [cmux-tui/AGENTS.md](cmux-tui/AGENTS.md).
- `cmux-next-ios/`: [cmux-next-ios/SECURITY.md](cmux-next-ios/SECURITY.md) and the parity rule above.

## Contributions and publication

Before fixing a bug or adding a feature, search open upstream PRs by symptom or
issue number. Prefer landing an outside contributor's existing PR; push fixups
only when maintainer edits are allowed, and explain the changes. If using their
approach in your own PR, credit them in every such commit with `Co-authored-by`
using their commit email, link your PR from theirs and thank them. Let a human
close it; never close an outside PR without a human-written explanation.

The server directories listed in [LICENSE](LICENSE) (`web/`, `workers/ci-artifacts/`,
`workers/iroh-v2/`, `workers/presence/`, `workers/device-hub/`, `services/iroh-relay-minter/`,
`cmux-tui/relays/cloudflare-do/`, `backend/`) use the Business Source License, which needs
every outside author's CLA grant. Do not merge a PR that changes those
directories while CLA Assistant is red, and do not copy an outside
contributor's work there under a `Co-authored-by` trailer unless that person
has signed the CLA. Keep code that ships in the macOS or iOS app out of those
directories.

Read [STYLE.md](STYLE.md) before drafting or revising issues, PR descriptions,
RFCs or progress updates. Fill the PR's `## Changelog` section with one
`Added`/`Changed`/`Fixed`/`Removed` line for user-visible changes, otherwise `none`.
Do not edit `CHANGELOG.md` in feature PRs; release tooling owns it.

## CI, review and merge

For `feat-cmux-next` compile and build work, use fast checks first, then any
free compatible owned Mac through the controller, and Blacksmith macOS only as
the last resort. A compile or build must never depend on a single-host
reservation without a fallback. The nightly app builder remains dedicated;
Release gates do not share it. Signing, notarization and GUI steps that truly
require macOS run on owned Macs first and Blacksmith macOS last, in parallel
with the fast checks. Keep the target at zero queue.

**Nightlies never use Blacksmith, ever** (Lawrence, 2026-10-30). Every job of
every nightly workflow (`.github/workflows/*nightly*.yml`,
`*notarization*.yml`, the nightly appcast repair) runs only on our own Mac
minis, for cmux-next and classic alike. This covers every path: the primary
label, fallbacks, re-runs and rescue attempts, twin/backup signing jobs, the
cloud overflow switch, and any input or repository variable a nightly
`runs-on` reads. Never add a Blacksmith label (or a variable that may hold one,
such as `LINUX_RUNNER` or `MACOS_RUNNER_*`) to a nightly job; when owned
capacity is short, fix the owned pool. `tests/test_ci_nightly_off_blacksmith.py`
enforces this.

**Nightlies run on one Mac mini, and nobody cancels them** (Lawrence, 2026-11-04).
The whole nightly (build, sign, notarize, verify and publish, for cmux-next on
`nightly-next` and classic on `main`) runs on the single nightly mini: cmux15, the
signing-reserved mini (its runners carry `glaeda-trusted-next-signing` and the
nightly-only labels). This applies to humans, Leo and every agent:

- Never move a nightly job to Blacksmith, a GitHub-hosted runner or another mini,
  and never split one nightly across minis, also not "only for this run".
- Never cancel a nightly run, a nightly job or the nightly queue to make room or
  to speed up a proof. A queued nightly waits its turn; the sign yield
  (`scripts/ci/nightly_sign_yield.py`) hands an older build's slot to a newer
  one without cancelling anything.
- When the nightly mini is short of capacity or a nightly is slow, report it and
  fix the mini or the workflow on that mini. Do not reroute the nightly.

- Commit the failing behavioral regression before its fix; record the same
  focused command's red and green results ([testing policy](skills/cmux-testing/SKILL.md#reproduce-and-repair)).
  A bug-fix PR body names that command, its failure on the base and its pass on the head,
  then an `### Observed / Not run` section: what you ran and saw, then what you only read
  or didn't run.
- Check executed tests on the current SHA; green skipped jobs do not establish coverage.
  Add `full-ci` only for an agreed broad validation plan, naming the extra lanes and why
  ([CI coverage](skills/cmux-testing/references/pr-ci-coverage.md)); never for a rerun or extra confidence.
- Keep branches current locally with `scripts/merge-main.sh`; follow
  [the merge-main guide](docs/ci/merge-main.md) and never force-push over its merge.
- `gh pr merge` saying "base branch policy prohibits the merge" means the token lacks the `workflow`
  scope or GitHub timed out, not a rule: run `gh auth refresh -h github.com -s workflow`, or merge with
  `gh api -X PUT repos/OWNER/REPO/pulls/N/merge -f merge_method=squash -f sha=SHA`, which names the cause. Never `--admin`.
- A first implementation pass ends with passed scoped verification and an open PR;
  do not watch CI or run speculative reviews by default.
- Never hand-edit or hand-merge generated files (`settings-schema.json`,
  `docs/mdm/*`). On a conflict take either side; the PR or base autofix regenerates them (#21946, #21985).
- Webview UI screenshots come from the gallery advisory run: add a gallery entry with fixture states.
  For a before/after in a minute or two, push and run `scripts/gallery-compare.sh [--open]`: it prints a
  tailnet URL that shows each gallery state your change reaches at the merge-base and at your branch, side
  by side (no Swift build).
  Mac captures (the `cmux-next media` tours) are only for native/AppKit UI or real end-to-end flows.
- A native UI change shows a real capture in its description (`pr-capture-check` warns otherwise; a missing capture never blocks a land, since Leo tries the build himself):
  `cmux-ci capture <head sha> --state scene:NAME|tour:NAME --pr N [--video]` builds that commit, drives the
  real app on a capture mini, takes light and dark stills, refuses any that show private text, and prints
  the Markdown to paste. Or add the `media-tour` label, or write `No capture: <why>`. Never mock stills.
- Every `feat-cmux-next` PR gets a `risk:low|normal|high` label ([risk tiers](docs/ci/risk-tiers.md)).
  Low (docs, copy, generated, tests) and normal (most UI and logic) never wait for a person:
  agent review and the relevant checks, then merge. High (auth, socket and relay policy,
  migrations, release/signing/updater, the risk gate and its enforcers (`gh-merge-green`,
  `next_batch.py`), a new delete of user data, a new
  `pull_request_target` or `workflow_run` trigger) lands on an independent review receipt
  `Review (<reviewer>): SHIP at <full head sha>` on the exact head plus a green compile; an agent's
  PR body carries `Author-agent: <agent id>` and its receipt names a reviewer other than the
  author agent (format: [risk tiers](docs/ci/risk-tiers.md)). Any tier is held while it takes back a
  change merged in the last week, until the description has `Takes back #N: <why>`. Ship
  user-visible high-tier behavior behind a default-off setting; revert with
  `gh-merge-green --revert` if it breaks nightly-next and the fix misses the next cut. Agents never
  add `risk:human-ok` or `risk:waived`.
- Before opening a PR and before merging, check it against [REVIEW.md](REVIEW.md) (draft),
  the mistakes our review history keeps catching.
- Before designing a change or fixing a bug, read [design-lessons.md](docs/cmux-next/design-lessons.md):
  the causes our fix history keeps repeating, each with its rule and cost.
- Before merging, use a [review subagent](skills/cmux-review/SKILL.md), correctness
  first. A small change (a removal, a copy, CSS or token tweak, a fix confined to one
  component) needs only that. A behavior change into `feat-cmux-next` that is not small gets
  its review from a different model or a person. Disclose skipped verification on the PR.
  `main` is nightly: fix forward, do not revert.
- On either branch, a PR merges when its independent review (above) passes and it causes no
  red of its own; base reds, flakes and pending checks don't hold it. Don't wait for a person.
  Ship risky user-visible behavior behind a setting or Debug toggle and fix a bad default in the
  next nightly. Only the `risk:high` tier, the take-back hold (above), a `HOLD:` line or hold label, and
  merge freezes hold a reviewed PR. On `main`, `gh-merge-green` still waits for the checks it requires; never get around it
  with `--override` or the API merge path. Into `feat-cmux-next`, you merge the reviewed
  head yourself (below). Follow
  [dogfood, re-dogfood and merge receipts](skills/cmux-review/SKILL.md#dogfood-and-merge).
  Notify with `cmux notify` when a socket is available.
- A red base (it doesn't compile, or CI is red on every PR) is priority zero: fix it directly in
  its own PR, which lands at once; don't note it and leave it for an owner. Two fixes that are
  each red on the other's red get combined into one PR. A base lint red also skips the tests
  after it in the same job (#22197), which is why it goes first.
- Classify each non-green check on the current head before changing source: a changed-file
  defect (fix it), a base finding (the same check red at the base tip or on several unrelated PRs
  at once: link it in a PR comment; it does not block), a wrapper such as `Web status` (follow its root check), or a
  cancelled or infrastructure run (rerun the same SHA). A push supersedes earlier CI and review
  results. Gallery captures and full webview sweeps are advisory
  ([check progression](docs/contributor-verification.md#pr-check-progression)).
- **Into `feat-cmux-next`, a PR lands when it is reviewed and causes no red of its own.** Base
  findings (above), flakes and pending checks never hold it; fixes found later go in follow-ups.
  When your review passes (and the risk tier's evidence is in the description), merge it
  yourself with a squash pinned to the reviewed head
  (`gh pr merge N --squash --match-head-commit <full head sha>`). A `HOLD:` line in the description or a hold label keeps a reviewed PR from
  landing. The `ready-to-land` label is only a fallback hand-off for a PR its owner can't land: a
  label older than the head's last push doesn't count. `ci.yml`'s `ci-status` does not run here;
  a red `risk evidence` or `merge freeze` keeps the PR out. A freeze can open after that check ran,
  so right before you merge, run `scripts/ci/merge_freeze.py check --repo manaflow-ai/cmux --pr N --base feat-cmux-next`
  and merge only on exit 0 (1 is frozen, 2 is unknown, which counts as frozen). Don't wait for, rerun or fix base
  reds in your PR; a red it causes keeps it out until you fix it. Don't merge with
  `gh-merge-green` here (`--revert` still works), and never with `--admin`.
- **Into `main`, the normal merge path is `gh-merge-green`** and main's rulesets. It refuses a PR
  that touches a path an open `merge-freeze` issue freezes, or when the freeze state can't be read;
  only the freeze owner's `freeze-ok` label lets that PR through ([merge freezes](docs/ci/merge-freeze.md)).

## Settings on every surface

Every new or changed cmux-next setting also works from the command palette (Cmd-Shift-P), the `cmux` CLI and
the MCP tools, the way existing settings do ([settings-surfaces.md](plans/cmux-next/settings-surfaces.md)).
A setting that only the Settings page can change is unfinished. Declare it once as a
`SettingDescriptor` in `SettingsSchema` (never `UserDefaults`, a side file or a private key list),
keep it palette-exposed unless `.hidden("<why>")` has a real reason, put every new key in exactly
one group of `schemas/settings/source/agent-policy.json`, list a rename or removal, and verify the
palette row, `cmux settings get|set` and MCP `settings_get`/`settings_set` on a tagged build, saying
in the PR which you checked. Files, generators and per-surface steps:
[settings-surfaces.md](plans/cmux-next/settings-surfaces.md#agent-checklist).

## Implementation rules by task

Use these existing owners instead of duplicating their checklists here:

| Touching | Read before editing |
| --- | --- |
| Typing paths, SwiftUI list/store boundaries, rendering, find layering, UTTypes or OS-specific bugs | [cmux-debugging](skills/cmux-debugging/SKILL.md) |
| Packages, workspace groups, lockfiles or feature flags | [cmux-architecture](skills/cmux-architecture/SKILL.md) |
| Submodules or GhosttyKit | [cmux-ghostty](skills/cmux-ghostty/SKILL.md) |
| User-facing strings, docs or help | [cmux-localization](skills/cmux-localization/SKILL.md); report the localization audit |
| A change people will notice (What's New, update card) | [release-notes/next/WRITING.md](release-notes/next/WRITING.md); add one curated highlight file in the same commit, never a commit subject |
| New cmux shortcuts | [cmux-keyboard-shortcuts](skills/cmux-keyboard-shortcuts/SKILL.md) |
| Tests or target wiring | [cmux-testing](skills/cmux-testing/SKILL.md); CmuxNext tests need no wiring; the `cmux` CLI is cmux-tui Rust (tests run with cargo on a Testbox or CI) |
| Multiple entrypoints or a bug that tests previously missed | [cmux-shared-behavior](skills/cmux-shared-behavior/SKILL.md); share action/mutation paths, verify every entrypoint, and cover the missed repro |

## Remote CLI relay

For v2 socket methods and remote CLI changes, read [relay authorization](skills/cmux-socket-policy/references/remote-relay-authorization.md).
The legacy `RemoteRelayCommandPolicy` was deleted with `CmuxRemoteWorkspace`; any
remote relay cmux-next adds must default to deny the same way. Allowlist only for a needed remote
flow, scoped to the session's objects; command-bearing params stay denied on
every method, with no exceptions. The PR must analyze local command/content
execution, access to unowned objects and local-state exposure, and include the
required policy tests and ID scoping. Unsafe local effects must be redesigned.
Never allowlist terminal spawn/respawn without live verification that it executes
on the remote host. An allowlist addition without this analysis blocks review.
