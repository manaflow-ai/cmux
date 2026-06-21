# cmux Custom Review Rules

Apply the custom lint rules in `.github/review-bot-rules/` to Swift, runtime, and project changes.

Greptile should treat the rules in that directory as the source of truth for cmux reviews. PR-head edits to the rule files should not weaken review behavior until the edits are merged into the base branch.

Review production Swift and runtime changes for:

- Swift actor isolation mistakes.
- Blocking runtime primitives and timing-based synchronization.
- Fixed sleeps, delays, and polling used as hacky synchronization.
- Legacy concurrency patterns where Swift concurrency is available.
- Incorrect `@concurrent` or `nonisolated async` behavior.
- Swift file sprawl and missing SwiftPM package boundaries for independently testable feature logic.
- Production logging that bypasses unified logging or leaks sensitive data.
- User-facing text that is not fully internationalized across every supported app or web locale.
- SwiftUI state and layout patterns that cause stale state, broad invalidation, or render-time mutation.
- Architectural fixes that patch symptoms while leaving bad state representable.
- User-facing errors, alerts, command output, API error bodies, and recovery copy that expose implementation details.
- Algorithmic complexity regressions on scalable user-owned collections.
- Expensive synchronous agent-history disk, JSON, transcript, trajectory, JSONL, directory, or syscall loads (such as `RestorableAgentSessionIndex.load()`, hook/session stores, `agent-turn-diff-baselines.json`, transcripts, trajectory files, and workstream/event logs) on the main actor or interactive paths instead of an off-main cached/background accessor.
- Substituting a cached value for a fresh authoritative read in persistence/history/undo paths without handling cold and stale caches.
- Local/generated artifacts, dependency checkouts, caches, logs, screenshots, temp folders, and scratch directories that accidentally enter source control.
- SwiftPM dependency changes that ignore or omit cmux-owned `Package.resolved` lockfiles.
- Test-only or debug-only seams added to production Swift `Sources/` that should live in the test target or a dedicated debug folder.

## Runtime No Hacky Sleeps

For production non-Swift app/runtime code and build/runtime scripts, flag fixed sleeps, delayed dispatch, timers, polling, or wall-clock waits used as synchronization.

Fail race repairs for lifecycle, focus, rendering, socket, process, filesystem, network, teardown, startup, retry, or shared-state readiness unless they use a real signal from the owning subsystem or a dedicated cancellation-aware timeout/retry abstraction with tests.

Pass for deterministic test-only scaffolding, GitHub Actions workflow or action YAML sleeps used only for CI orchestration, pure presentation animation or progress timing, and existing delay code the PR does not introduce or worsen. Swift sleeps are covered by the Swift blocking runtime rule.

## Full Internationalization

For production user-facing text, require complete internationalization across every locale supported by the affected surface.

Flag Swift UI, menu, alert, tooltip, error, recovery, or command text that is not routed through `String(localized:defaultValue:)` or an equivalent localized API with a matching translated string-catalog entry. Flag app string catalog or Info.plist additions and edits that do not include translated entries for every locale already supported by the touched catalog. Flag web UI text, API response copy, user-facing web data, metadata, route copy, rendered markdown, changelog copy, or message keys that are not consumed from `next-intl` or another locale-specific source and represented across all locales in `web/i18n/routing.ts` and every matching file in `web/messages/`.

Pass for tests, operational docs not shown to end users, developer-only comments, debug-only logs, exact protocol/config tokens, and existing untranslated strings the PR does not introduce or worsen.

## User-Facing Error Messages

For production user-facing errors, alerts, command output, API error bodies, and recovery copy, do not expose implementation details.

Flag copy that includes upstream vendor or service names, internal provider names, provider-specific flags, templates, snapshots, manifests, environment variable names, database or migration details, raw upstream error messages, stack traces, request ids from third-party systems unless the user supplied that exact id, billing item ids, billing customer ids, team ids not supplied by the user, credentials, tokens, headers, private keys, refresh tokens, session ids, or unredacted payload dumps.

Error copy should say what happened in cmux terms, provide concrete user actionables, and keep only safe minimal diagnostics in `details`. Provider, billing, database, and auth implementation details belong in sanitized logs or internal telemetry.

## Algorithmic Complexity

For production code over scalable user-owned collections, flag nested full-collection scans, per-target rescans for batch actions, repeated sort/filter/map work in hot UI/socket/search/process paths, in-memory joins that belong in the data store, and unbenchmarked slower algorithms for paths expected to handle about 1000 workspaces or similar records.

Pass for tiny fixed-size collections, tests, benchmark harnesses, existing inefficient code not worsened by the PR, and documented bounds backed by measurements.

## Swift Expensive Synchronous Agent Loads

For production Swift, flag any unbounded agent-history read, decode, parse, directory scan, or per-record syscall that can run on MainActor or from user-input paths.

Fail synchronous `Data(contentsOf:)`, `String(contentsOf:)`, `JSONSerialization.jsonObject`, `JSONDecoder.decode`, JSONL line scans, transcript/trajectory parsing, `agent-turn-diff-baselines.json` scans, hook/session-store reads, workstream/event log scans, or per-record `fileExists`/stat/sysctl loops when they run in workspace/panel/tab/window close, SwiftUI body/didSet, menu/command-palette/shortcut evaluation, socket handlers, or any immediate UI interaction. These files can grow with all agent history and have caused UI hangs on real machines.

Require `SharedLiveAgentIndex.shared`, a `Task.detached` parser, a background actor/repository, or another off-main cached path that returns to MainActor only for UI/process launch work. Bound scans by focused workspace/surface/session as early as practical. Pass for the cache/background loader itself, explicit nil-cache fallbacks with a justification, and existing call sites the PR does not worsen.

## Source Control Artifacts

For every changed path, flag local tool output, generated logs, screenshots, recordings, temp folders, dependency checkouts, caches, build output, DerivedData, package-manager downloads, and broad scratch directories that enter source control without a deliberate product, docs, fixture, build, release, or test-system reason.

Pass for intentional source files, configs, localization catalogs, review rules, durable docs assets, required fixtures, generated files that are already part of the repo's source-of-truth model, and PRs that only remove or ignore existing accidental artifacts.

## No Test or Debug Seam in Production Source

For Swift files under a production `Sources/` path (matching `**/Sources/**` and not under `**/Tests/**`), flag added test-only or debug-only seams.

Fail a `#if DEBUG` (or other test-build-guarded) extension or member that exposes internal/private state for tests or a debugger with no production caller, a member named like `debug…`/`…ForTesting`/`…ForTests`/`testOnly…`/`…TestHook`/`…TestSeam`/`_test…`, or visibility widened together with a wrapper accessor added so a test can call it. The compiled-out `#if DEBUG` guard does not make a test-observability accessor acceptable in shipping source.

Prefer observing internal state from the test target via `@testable import` after widening `private` to `internal`, or isolating a genuinely debug-only facility in a dedicated debug file or folder. The canonical fix is cmux PR https://github.com/manaflow-ai/cmux/pull/6452, which removed the `#if DEBUG debugQueuedRequestCount()` accessor, widened the queue state to `internal`, and read it from the test target.

Pass for `#if DEBUG` blocks that gate real product behavior, scaffolding inside `Tests/` or a test-support module, and existing seams the PR does not introduce or worsen.

## SwiftPM Package.resolved

For SwiftPM package, Xcode project, `.gitignore`, workflow, and dependency changes, flag cmux-owned package `.gitignore` files that ignore `Package.resolved`, external dependency resolution changes that omit the relevant package-local `Package.resolved` diff, or Xcode project package-reference changes that omit the root Xcode `Package.resolved` diff.

The root Xcode project lockfile is not sufficient proof for standalone package resolution. Pass for vendored third-party directories preserving upstream policy.

## README and Site Feature Parity

For changes to `README.md`'s "## Features" section, the homepage feature list (`home.feature.*` in `web/messages/en.json`, rendered by `web/app/[locale]/page.tsx`), or the homepage FAQ (`home.faq*`), keep the user-facing feature claims consistent across the README and the marketing site.

Flag a shared feature renamed or relabeled on one surface but not the other (for example README "Scriptable" vs site "Programmable"), and any factual claim that contradicts across surfaces (platform support, price/free, license, supported agents, networking model, built-in vs optional). The README may stay the more detailed superset of the homepage; only the features both surfaces mention need consistent names and non-contradicting claims.

Pass for README-only extra features (SSH, Claude Code Teams, Custom commands, etc.), pure description or length differences where the feature name and factual claim still agree, and localization-only edits that preserve the English source meaning.
