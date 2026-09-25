# cmux agent notes

## Setup

`./scripts/setup.sh` initializes submodules, builds GhosttyKit, and installs the pbxproj normalization pre-commit hook.

Before committing, setup or a native build, [choose verification for the changed area](skills/cmux-testing/references/local-vs-ci-validation.md). `python3 scripts/verify-local.py` runs fast static checks; docs and portable-tooling changes do not automatically require an app build. Run it only on code you trust: the checker executes repository scripts, including those in a `--repo` target. There is no automatic candidate-code execution on push; see the [trust boundary](docs/contributor-verification.md#trust-boundary).

## Dev builds on the Mac mini fleet

For team dev builds, use the controller client `~/.local/bin/cmux-ci`. The Mac
mini fleet is **dev-build-only**. Owned minis will take pull request jobs
through the pool picker (`scripts/ci/pr_runner_pool.py`, `POOLS`); the earlier
persistent compile pilot is retired. Release, signing, notarization, nightly,
TestFlight, merge-queue policy, generic agent execution, and every GUI or
runtime test remain on their existing lanes. A successful dev build never
replaces a required check.

Before submitting, read the current [HQ AGENTS.md](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/AGENTS.md)
and [agent build contract](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/build-fleet/AGENT-BUILDS.md).
These are the authoritative fleet instructions even when an old PR worktree has
copied instructions. `AGENTS.md` in this repository is a symlink to this file.

Commit and push the intended edits first. This builds the exact pushed SHA;
it does not upload dirty local edits. Use the PR owner's GitHub login for
`SUBMITTER` (for example `lawrencecchen` or `austinywang`), the full PR URL for
`PR_URL`, and preserve both receipts:

```bash
SHA=$(git rev-parse HEAD)
PR_URL=https://github.com/manaflow-ai/cmux/pull/123
SUBMITTER=lawrencecchen
mkdir -p artifacts/fleet
JOB_JSON=$(~/.local/bin/cmux-ci build cmux --ref "$SHA" \
  --workspace "$PR_URL" --submitter "$SUBMITTER" \
  --receipt "artifacts/fleet/$SHA-submit.json")
JOB_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$JOB_JSON")
~/.local/bin/cmux-ci wait "$JOB_ID" --receipt "artifacts/fleet/$SHA-terminal.json" && \
  ~/.local/bin/cmux-ci publish-hq "$JOB_ID"
```

Run `publish-hq` only after `wait` succeeds. Return the job ID immediately to a
requesting agent, then the receipts and HQ download link when complete. If
`wait` times out, wait again on the same ID; do not submit a duplicate. The job
continues if the submitting laptop disconnects. The installed client loads a
private credential file; never print it or copy secrets into PR evidence.

Use the client's workload defaults: **120 GiB for CMUX**, **250 GiB for a cold
Chromium build**. The former blanket 250 GiB CMUX requirement is obsolete.
Do not copy it into new requests or bypass a rejection with an arbitrary lower
floor. A validated Chromium warm profile may use 200 GiB through the runbook's
compatibility-receipt workflow. Report a controller/worker policy mismatch;
queueing is not permission to build over SSH.

The disk daemon owns cleanup under the host lock. Do not remove shared caches,
active workspaces, or other agents' builds to make space. Retain the terminal
receipt's timing, cache, disk, cleanup, and artifact evidence. A cached artifact
replay is not a changed-source warm compilation benchmark.

### Shared-machine execution ownership

The controller job/reservation and the host's physical execution lease are
separate identities. `cmux-ci`, GitHub Actions, direct agents, and operator
commands may share one CMUX-owned machine while keeping their own caller and
workflow state.

When a controller has already reserved a machine, the execution adapter
validates that reservation and binds its local lease to the same ownership
evidence. A target-machine choice without reservation still goes through fresh
host admission. Native build lanes, heavy Linux slots, project locks, publisher slots, and
resident workspaces must have one local owner before execution starts.

A busy/idle guess, runner process, SSH session, or process-name check never
grants or releases that ownership. Keep using the existing controller job ID for
retries, and preserve its receipts; host refusal or pressure should flow back to
the caller instead of being bypassed through direct execution.

### Fleet allocation transition

The macfleet skill is retired. Do not load, invoke, reinstall, or follow it.
Do not start new maclease workloads, including `reload-cloud`, `tsadmin builder`,
or `verify-remote` flows that allocate through maclease. Use the controller where
supported and report missing recipe support rather than bypassing scheduling.
Existing jobs may complete and release their reservations. Direct SSH and
`tsadmin` remain available for administration and diagnostics; do not change SSH
keys, Tailscale, or host access as part of this transition.

### Tagged builds outside the team fleet

Reuse the tag's warm DerivedData and published dependencies before a cold
build. For prebuilt GhosttyKit, run `./scripts/download-prebuilt-ghosttykit.sh`,
then use `CMUX_GHOSTTYKIT_PREPROVISIONED=1` with the tagged reload. The download
verifies the pinned artifact.

Always build with a tag. **Never run bare `xcodebuild` or open an untagged
`cmux DEV.app`**: untagged builds share the default debug socket and bundle ID
with other agents. The fleet publishes isolated tags through HQ. Report the
`publish-hq` URL as a Markdown link so HQ can restore/download the build; never
substitute a raw `.app` path or a `file://` URL.

For standalone contributors without the team controller, the local workflow is
`./scripts/reload.sh --tag <branch-slug>` (build without launch) or the same
command with `--launch`. This is not a queue-bypass fallback for team agents.
Other local variants remain `reloadp.sh` (Release), `reloads.sh` (isolated
Release staging), and `reload2.sh --tag <tag>` (both). Local compile-only checks
must use the tagged DerivedData directory rather than an untagged default.
Clean up only tags you own; retain DerivedData while an active task needs it.

Standalone local compile-only check, reusing the tag's DerivedData:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/cmux-<tag>" build
```

`<tag>` is the slug `reload.sh` makes: lowercase, with runs of other characters
replaced by `-` (`Fix/ABC-1` becomes `fix-abc-1`). A different path starts a cold
build. When GhosttyKit itself needs rebuilding (see prebuilt reuse above):

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

### Intel Macs, Xcode 16.2, Swift 6.0

The macOS app also builds on Intel Macs running macOS 14 with Xcode 16.2 (Swift 6.0.3), including tagged `./scripts/reload.sh` dev builds; `GhosttyKit.xcframework` already ships fat x86_64+arm64 slices targeting macOS 13. Xcode 26 stays the pinned toolchain (`.xcode-version`) for CI, releases, and the iOS app; this pathway is best effort and changes nothing for Xcode 26. Code linked into the macOS app (`Sources/`, `CLI/`, `TunnelExtension/`, and the packages it depends on) stays within Swift 6.0 syntax: no trailing commas in parameter or argument lists (SE-0439, Swift 6.1), no `nonisolated` on struct/enum/class/protocol declarations (SE-0449, Swift 6.1; member-level `nonisolated` is fine), and the existing `#if compiler(>=6.2)` / `#else @Sendable` split for `@concurrent` (SE-0461 is Swift 6.2; the Swift 6.0 compiler does not implement it and only warns that the attribute was renamed, so it must not be relied on for the 6.2 semantics). macOS 26-only APIs stay behind their `@available`/`#available` checks and are simply unavailable at runtime on macOS 14. `cmuxTests/`, `cmuxUITests/`, and `Packages/iOS/` are outside this pathway.

## Tag-bound debug CLI

For CLI or socket dogfood against a tagged Debug app, set `CMUX_TAG` and use the helper. Do not use `/tmp/cmux-cli`, which points at the most recently reloaded build and can target the user's main app socket.

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper refuses to run without `CMUX_TAG`, targets `/tmp/cmux-debug-<tag>.sock`, and uses the matching tagged CLI from DerivedData. It scrubs ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, workspace/surface/tab/panel IDs, cmuxd socket, debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH` for the tag.

## Area-specific instructions

Rules that only matter in one part of the tree live next to that code. Read the file before working there; not every agent loads a nested file on its own when launched from the repository root.

- `ios/`, `Packages/iOS/`: `ios/AGENTS.md` (Apple HIG rule, iPhone install and auth gates, iOS and verification capacity on the controller, cross-tag Mac access, dev auth profiles).
- `web/` and any cmux Cloud database work: `web/AGENTS.md` (database provider).
- `cmux-tui/`: `cmux-tui/AGENTS.md` (hosted verification, Blacksmith Testbox).

## Public writing

Before drafting or revising a top-level issue or PR description, read [STYLE.md](STYLE.md). It also covers RFCs and progress updates.

## Parallel sessions

Several agent sessions work this repo at once and cannot see each other. They push through one GitHub account, so `author` and `mergedBy` name the account, never which session acted. Do not infer from them that a particular session opened, merged, or reviewed something, and do not report that to the user as fact.

The failure mode is duplicate work, not merge conflicts. A shared observable — a red `main`, a failing required check — reaches every session at once, and each independently diagnoses it and opens a PR. On 2026-09-22 five PRs landed on one test function, `test_ci_executes_review_fabric_contracts`, in twenty-one minutes: #13785, #13788, #13800, #13801, #13802. Two of them were opened five seconds apart.

Before `gh pr create`:

1. `git fetch upstream` and re-check the defect against current `upstream/main`, not the commit in the report. Main moves several commits an hour, so a reported SHA is usually stale and often already fixed.
2. `gh search prs --repo manaflow-ai/cmux --state open '<failing test or file>'`. Search the failing symbol, not your own PR title: sessions converge on the symbol and diverge on titles.
3. Check for a session already on it (Claude Code: `ListAgents`) and message it before you push.
4. Run `git worktree list` and inspect the branches in other local worktrees for an existing fix before starting a duplicate.
5. Run `git for-each-ref --sort=-committerdate --count=20 --format='%(committerdate:iso8601) %(refname:short) %(subject)' refs/remotes/` after fetching. Inspect recent remote branches for a fix that has not reached an open PR yet; commit dates indicate recent work, not when a branch was pushed.

Query `state` before acting on any PR. GitHub keeps serving `mergeable` and `mergeStateStatus` on closed and merged PRs, where they mean nothing; reading `CONFLICTING` off an already-merged PR has twice sent a session to resolve a conflict that did not exist.

If the fix already exists, say so and stop. When a duplicate is already open, close yours in favour of the earlier one and move any genuine improvement to a comment on it — that costs less review attention than a second PR carrying one extra idea.

Overlapping files are not evidence of a duplicate. #13754 and #13797 changed exactly the same two files and fixed different bugs — one made the seeder run on the pool that PR admission restores from, the other stopped it restoring its own last seed — and both merged. Read what each PR asserts, and if they look compatible, merge one into the other locally and run the shared test before proposing that either close.

### Callsigns

A callsign names the worker session behind a piece of work, because `author` and `mergedBy` only ever name the shared push account. Reserve one before your first substantive publication, then sign what you produce with it.

The registry is `teamleaderleo/stensibly` issue #454, driven by a `github-actions[bot]` registrar; the worker quickstart is `docs/callsign-registry-dogfood.md` in that repo. Reserve with a name not in active or recent history:

```text
/callsign reserve <Callsign>
run: run_<unique-run-id>
session: <unique-worker-session-id>
ttl: 24h
```

The bot answers in seconds with a `callsign-receipt/v0` carrying the accepted `generation`, a derived `sigil`, and an `expires-at`. Release the exact generation when the session ends. Sign substantive comments, reviews, PR descriptions and handoffs as `— <Callsign> g<generation> <sigil>`, with the run id and current intention beneath when the context is not obvious.

Three things about it are easy to get wrong:

- **The sigil is derived, not chosen.** The registrar computes it from the callsign; picking your own emoji produces a sigil that does not match your receipt. `Teakettle` derives `💾`.
- **Names are leased, not self-assigned.** Collision keys ignore case and separators, so `Rook`, `rook` and `r-o_o k` are one name. Do not reuse a prior worker's callsign without a fresh accepted generation; a matching name never proves continuity.
- **Show a generation only from an accepted receipt.** If registration is pending or the registrar is unavailable, say `pending` or `unregistered` and keep the exact run and session values rather than inventing a number.

A callsign is attribution, never authority. The worker attempt is identified by `callsign + run ID + session ID + lease generation`; that tuple records who acted and grants nothing. Do not gate an action on a callsign, and do not treat a comment bearing one as authenticated — marker text is not an authenticated principal, which is the defect `teamleaderleo/quarry` #1103 tracks.

## Outside contributors

Most open PRs from people outside the team never got a human reply: of 810 open on 2026-09-23, 765 had only bot comments. Several were fixed on `main` by a maintainer PR while the contributor's PR sat open, and the contributor found out on their own.

Before fixing a bug or building a feature, run `gh search prs --repo manaflow-ai/cmux --state open '<symptom or issue number>'` and look for an outside PR (author not on the team). If one exists:

- Prefer landing theirs. Push fixups to their branch when "Allow edits by maintainers" is on, and say what you changed.
- If you write your own fix instead, add `Co-authored-by: Name <email>` for them to every commit that uses their approach, using the email from their commits (`git log --format='%an <%ae>'` on their branch). Then comment on their PR with a link to yours and a plain thank-you, and let a human close it.
- Never close an outside PR without a human-written comment saying why.

## Choosing CI coverage

`full-ci` requests the expensive full macOS suite policy. It is not shorthand
for normal PR checks, relevant tests, review readiness, or permission to merge.
Do not add it as a generic review or merge requirement. First identify the
lanes needed by the change and use existing routed checks or targeted validation.
Add `full-ci` only when the user or agreed validation plan explicitly calls for
the broad suite; state which additional lanes are needed and why.

Normal PR CI can already run routed tests, including Swift package and CLI
wrapper checks, without `full-ci`. A `cmuxTests/` diff runs the suites it
declares or extends on one app-host worker, with no label. `unit-ci` runs every
app-host suite across all seven workers; `full-ci` adds the other lanes on top.
Neither is needed to test the suites you edited. The label permits eligible app-host shards,
lag builds, and other full-suite lanes; path routing, release routing, and job
dependencies still apply. It does not request every repository test. Inspect
actual executed tests on the current SHA: a green skipped job is not coverage.
Adding or removing the label affects new event runs, not the label snapshot of
an existing run or a rerun of that event.

## Regression test commits

Keep two commits: first the failing behavioral regression, then the fix. Run the
same focused command on both and record the commit SHAs, expected failure, and
passing result. A setup failure or zero executed tests is not regression proof.
When this proof is available locally, push both commits together after the fix
passes; a separate hosted CI run on the deliberately broken intermediate commit
is unnecessary. If the failure only reproduces in CI, use that lane and retain
its receipts. Required CI and review still apply to the final pushed head.

## First pass, then dogfood

A first pass ends when the change is implemented, [scoped verification](skills/cmux-testing/references/local-vs-ci-validation.md) passed, and the PR is open. Native app/build-input changes require the tagged build on the pushed HEAD and focused tests; `web/` PRs also require the live Vercel preview URL. Docs and portable contributor tooling use their relevant checks without an unrelated app build. Then hand off; do not sit watching CI or running speculative review passes.

Do not launch a background review agent (`$autoreview`, `codex review`, `claude review`, or a judge loop) by default. Second-model review is explicit user opt-in in the current conversation; an implementation request, open PR, CI failure, closeout, or handoff is not that opt-in. Let required GitHub checks and review bots run asynchronously, then return to address only concrete check failures and actionable findings before merge.

The main agent owns dogfood, approval, mergeability, and every pushed fix. Merging app/runtime/UI changes requires the user's explicit approval after dogfood; if a fix changes runtime behavior mid-dogfood, rebuild the tag and re-notify, since the earlier verdict covers only the build the user tested.

Notify through `cmux notify` so the user can leave and return. Handoff: `--title "Dogfood ready: <short task>" --subtitle "<branch> · <tag>" --body "Was: <prior bad behavior>. Now: <expected behavior>. <concrete check>. PR: <pr-url>"`. Later closeout notifications use `"CI green: <branch>"` or `"CI blocked: <branch>"` with a one-line cause and the next decision. Titles carry outcome and branch, bodies carry the single next action. Skip notify if there is no cmux socket.

## Reading CI cost

Three measurements that are routinely read wrong, each established against
`test-e2e.yml` on 2026-09-23 over a 98-run window.

**A cancelled job's duration is usually queue, not spend.** GitHub sets a
queued job's `started_at` to when it entered the queue, so a run that waited 45
minutes for a runner and was then cancelled reports a 45-minute job. Check
`runner_name` and `steps`: both empty means no runner was ever assigned and the
job burned nothing. Of 20 cancelled runs totalling an apparent 239 macOS
runner-minutes, 15 never got a runner and the real spend was 46. All 15 were
waiting on `blacksmith-6vcpu-macos-15`, whose queue then ran a 26-minute median
against 0.6 minutes for the macOS 26 pool.

**Compiling fewer schemes saves almost nothing.** `build-for-testing` over
`cmux`, `cmux-unit` and `cmux-numeric-locale` costs 691 s, 28 s and 16 s. The
app scheme is 94% of it and is the test host every app-host test needs, so
selecting schemes per test target is not a lever. What the schemes cost is
worth re-measuring before any plan depends on splitting them.

**The compile is close to binary, and one file decides it.** Against the same
restored compilation cache, a revision with no changed native sources compiled
in 280 s; a revision differing by a single file in `Sources/` took 737 s. The
cause is not established (Debug builds are not whole-module), but "small diff"
does not mean "short build",
and a cache seeded from a commit that has since drifted is worth much less than
its hit rate suggests. Prefer adopting an already-compiled product over
reasoning about cache warmth.

## Pitfalls

Each of these has full detail in the skill named in parentheses.

- **Typing-latency-sensitive paths** (`cmux-debugging`): `WindowTerminalHostView.hitTest()` in `TerminalWindowPortal.swift`, `TabItemView` in `ContentView.swift`, and `TerminalSurface.forceRefresh()` in `GhosttyTerminalView.swift` run on every keystroke. Read the skill before touching them.
- **SwiftUI list boundaries** (`cmux-debugging`): no view below a `LazyVStack`/`LazyHStack`/`List`/`ForEach` boundary may hold an observable store reference, and no function called from `body` may write state. Violating either reintroduces the 100% CPU spin loop from https://github.com/manaflow-ai/cmux/issues/2586. Reference pattern: `IndexSectionActions` / `SectionGapActions` / `SessionSearchFn` in `Sources/SessionIndexView.swift`.
- **Do not add an app-level display link or manual `ghostty_surface_draw` loop.** Rely on Ghostty wakeups and its renderer, or typing lags.
- **Terminal find layering** (`cmux-debugging`): `SurfaceSearchOverlay` mounts from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), never from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.splittabbar.tabtransfer`, `com.cmux.sidebar-tab-reorder`).
- **Submodule safety** (`cmux-ghostty`): push the submodule commit to its remote `main` before committing the pointer in the parent repo. Never commit on a detached HEAD. Verify with `git merge-base --is-ancestor HEAD origin/main`.
- **Localize every user-facing string** (`cmux-localization`): `String(localized:)` with keys in `Resources/Localizable.xcstrings`, plus every web locale declared by `web/i18n/routing.ts` with a matching `web/messages/<locale>.json` entry. The supported macOS app locales are English, German, French, Arabic, Spanish, Traditional Chinese, Simplified Chinese, Korean, and Japanese (`en`, `de`, `fr`, `ar`, `es`, `zh-Hant`, `zh-Hans`, `ko`, `ja`). A localization audit is required for any UI, Settings, menu, schema, docs, or help-text change, and the handoff must state what was audited.
- **Shortcut policy** (`cmux-keyboard-shortcuts`): every new cmux-owned shortcut goes in `KeyboardShortcutSettings`, is editable in Settings, is supported in `~/.config/cmux/cmux.json`, and is documented.
- **Test wiring** (`cmux-testing`): a `.swift` file in `cmuxTests/` without a `PBXFileReference` + `PBXSourcesBuildPhase` entry is silently skipped, and both `xcodebuild test` and bot reviews pass with "Executed 0 tests". Run `./scripts/sync-test-wiring` after adding, renaming, or deleting a direct test file; `--check` is read-only. `workflow-guard-tests` keeps `./scripts/lint-pbxproj-test-wiring.sh` as the defensive guard.
- **SPM package groups** (`cmux-architecture`): packages live under `Packages/{Shared,iOS,macOS}/<pkg>` and the workspace mirrors that folder shape. To move one, `git mv` the directory then `python3 scripts/check-workspace-package-groups.py --write`. Never hand-edit workspace group membership.
- **Do not gitignore cmux-owned `Package.resolved`.** SwiftPM resolution changes must show in PR diffs; package-local lockfiles are not replaced by the root one. `python3 scripts/check-package-resolved-policy.py` fails on drift.
- **"Feature flag" means a remote PostHog runtime flag.** Implement through `CmuxFeatureFlags` with a PostHog key, explicit unavailable fallback, registry metadata, live update behavior, and focused tests. A local override may support dogfood but must not be the production control plane.
- **Foundation, SwiftUI, AttributeGraph, and WebKit semantics change between macOS major versions.** `URL(fileURLWithPath: "/").deletingLastPathComponent().path` returns `"/.."` on macOS 14 and 15 but `"/"` on macOS 26 (https://github.com/manaflow-ai/cmux/issues/4529); CI and maintainer machines were all on the fixed side while every reporter was on the broken side. Test on the reporter's macOS before declaring a repro disproven. AWS M4 Pro builders (`aws-m4pro-1..6`) run macOS 15.7.4.

## Shared behavior policy

When a behavior is exposed through multiple entrypoints (shortcut, command palette, context menu, CLI, settings, debug menu), implement one shared action path and verify every entrypoint. Do not patch one surface and leave the others with duplicated logic.

For optimistic UI or CLI updates, keep one mutation path, record pending state with a request id or previous snapshot, reconcile from the authoritative result, and roll back explicitly on failure. Do not let each entrypoint keep its own optimistic copy.

When a user says tests missed a bug, add behavior-level coverage around the exact repro path before claiming the fix is complete.

## Remote CLI relay authorization (GHSA-9vmv-3hjw-j28c)

Every v2 socket method you add or touch is a potential `cmux ssh` relay payload. The relay on the remote host authenticates but does not trust: `RemoteRelayCommandPolicy` (`Packages/macOS/CmuxRemoteWorkspace/Sources/CmuxRemoteWorkspace/Relay/`) denies every method by default and only forwards an allowlist, scoped to objects the remote session owns, with command-bearing params (`initial_command`, `command`, `tmux_start_command`, `pane_start_command`) denied on all methods.

Rules when adding a v2 method or a remote CLI command (`daemon/remote/cmd/cmuxd-remote/commands.go`):

- **Default is deny, and deny is safe.** A new method that is not added to the policy allowlist simply does not work through `cmux ssh`. Only add it when the remote product flow needs it.
- **Before allowlisting a method, answer in the PR description:** can it execute commands or open content on local objects (spawn terminals, respawn, send keys/text, eval scripts, open URLs)? Can it mutate or destroy objects the remote session does not own (close/rename/delete by ID)? Does it read local state the remote has no business seeing? If any answer is yes, do not allowlist it; reshape the method or its params instead.
- **Never allowlist a method that spawns or respawns terminals**, unless you have verified in the running app that the target executes on the remote host (the plain-SSH respawn path falls back to local execution under the same surface ID; that is why `surface.respawn` is denied).
- **ID params you introduce must be covered by the policy's scoped key sets** (`workspaceIDKeys`, `surfaceIDKeys`, `ambiguousIDKeys`, and the array variants). Adding a new `*_workspace_id`-shaped param name without extending the sets leaves it unscoped.
- **Add policy tests** (`RemoteCLIRelayPolicyTests`) for the new method: the allow case with an owned target, and the deny cases (unmapped target, command params).
- A PR that adds a method to the allowlist without this analysis must be treated as a security regression and blocked in review (enforced by `.github/review-bot-rules/remote-relay-authorization.md`).

## Skills

The [skill index](skills/README.md) separates contributor work from operating the
installed app. Use the task-specific skill before changing that area, then load
only the relevant references. Start with [cmux-dev-workflow](skills/cmux-dev-workflow/SKILL.md)
for setup/builds or [cmux-testing](skills/cmux-testing/SKILL.md) for verification.

- `cmux-dev-workflow`: setup, tagged reloads, Xcode project normalization, sidebar extension tagging, build isolation.
- `cmux-architecture`: package boundaries, file/API discipline, testability, Swift concurrency.
- `cmux-backend`: backend TypeScript, Effect, Cloud VM control plane, provider secrets, Postgres and migrations.
- `cmux-billing`: Stripe checkout, entitlements, webhooks, pricing dev stack, live provisioning.
- `cmux-cloud-vm`: driving cmux Cloud machines from the CLI (`cmux vm` exec/push/pull/wait, ports, checkpoints, forks) and the agent etiquette around them.
- `cmux-debugging`: debug event log, Debug menu, runtime pitfalls, typing-sensitive paths, SwiftUI list boundaries.
- `cmux-localization`: user-facing strings, localization files, shortcut text, localization audit.
- `cmux-testing`: regression policy, Swift Testing, test quality, test wiring, local vs CI validation.
- `cmux-socket-policy`: socket command threading and focus preservation.
- `cmux-shared-behavior`: shared action paths for multi-entrypoint behavior and optimistic updates.
- `cmux-ghostty`: Ghostty submodule and GhosttyKit workflow.
- `cmux-release`: release, version bump, changelog, pretag guard, release assets.

- Blacksmith Testbox (remote Linux builds for cmux-tui): warm your own box before any cmux-tui Rust or Zig
  build, and never compile cmux-tui on the Mac. The skill lives in cmuxterm-hq at
  `skills/infra/blacksmith-testbox/SKILL.md`; the workflows, `scripts/blacksmith-*.sh`, and the
  `tests/test_testbox_*` guards stay here. Quickest path: `./scripts/blacksmith-testbox-demo.sh`.
