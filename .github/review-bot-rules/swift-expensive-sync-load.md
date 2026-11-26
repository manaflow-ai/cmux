# Swift Expensive Synchronous Agent Loads

Flag heavy synchronous agent-history disk, JSON, transcript, trajectory, or syscall loads on the main actor or in interactive paths.

Report a failure when the diff adds or moves a call to an expensive whole-corpus loader onto a latency-sensitive path in non-test Swift. The canonical case is `RestorableAgentSessionIndex.load()`, which reads every agent kind's hook-store file from disk, resolves transcripts, and runs `sysctl(KERN_PROCARGS2)` per recorded session (measured 350ms-1.8s on machines with large agent history, and it scales with agent history, not tab count).

Also fail synchronous parsing or decoding of unbounded agent-owned files on the main actor or from user-input paths. This includes agent hook/session stores, `agent-turn-diff-baselines.json`, transcript files, trajectory files, workstream/event logs, or any large JSON/JSONL file whose size grows with agent history. A single `Data(contentsOf:)`, `String(contentsOf:)`, `JSONSerialization.jsonObject`, `JSONDecoder.decode`, line scan, directory walk, or per-record `fileExists`/stat loop is enough to flag when it can run on `@MainActor`, in menu/command-palette handling, shortcut handling, socket handlers, SwiftUI render paths, close/history paths, or other immediate UI interactions.

Treat any similarly heavy synchronous loader the same way: full-directory scans, per-record syscalls, broad JSON decode of unbounded files, or parsing that scales with all agent history instead of the focused workspace/surface/session.

Interactive / main-actor paths where this must not appear:

- workspace / panel / tab / window close and other close-history or session snapshotting
- SwiftUI `body`, `didSet`, menu or command-palette evaluation, row rendering
- socket / telemetry command handlers
- any `@MainActor` function reachable from user input

Required shape:

- Read the off-main, cached accessor instead (in cmux: `SharedLiveAgentIndex.shared`), which loads on a background task and serves a cached result.
- Move unavoidable large-file reads/parses into a non-main `Task.detached`, actor, or repository/service method with an explicit actor hop back to `@MainActor` only for UI/process launch work.
- Bound the scan to the focused workspace, surface, session, or target key as early as practical; avoid sorting or materializing the whole file when only the newest matching record is needed.
- A synchronous load is allowed only as a cold-cache fallback guarded by a nil-cache check, or inside the cache's own off-main loader. Such call sites should carry a brief justification comment.

Allowed cases:

- The cache's own background loader (`Task.detached`).
- A background parser that returns a small value and then hops back to `@MainActor` for UI work.
- An explicit cold-cache fallback such as `cache ?? RestorableAgentSessionIndex.load()`.
- Existing call sites the PR does not introduce or worsen.

When reporting, name the heavy loader or large agent file, the interactive path it now runs on, and the cached/off-main accessor or background parser that should replace it.

Background: this rule exists because a synchronous `RestorableAgentSessionIndex.load()` added to the workspace/tab close paths froze the UI 350ms-1.8s on every close (https://github.com/manaflow-ai/cmux/pull/5669).
