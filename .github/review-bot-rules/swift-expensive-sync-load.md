# Swift Expensive Synchronous Index Loads

Flag heavy synchronous disk/syscall loads on the main actor or in interactive paths.

Report a failure when the diff adds or moves a call to an expensive whole-corpus loader onto a latency-sensitive path in non-test Swift. The canonical case is `RestorableAgentSessionIndex.load()`, which reads every agent kind's hook-store file from disk, resolves transcripts, and runs `sysctl(KERN_PROCARGS2)` per recorded session (measured 350ms-1.8s on machines with large agent history, and it scales with agent history, not tab count). Treat any similarly heavy synchronous loader the same way: full-directory scans, per-record syscalls, or broad JSON decode of unbounded files.

Interactive / main-actor paths where this must not appear:

- workspace / panel / tab / window close and other close-history or session snapshotting
- SwiftUI `body`, `didSet`, menu or command-palette evaluation, row rendering
- socket / telemetry command handlers
- any `@MainActor` function reachable from user input

Required shape:

- Read the off-main, cached accessor instead (in cmux: `SharedLiveAgentIndex.shared`), which loads on a background task and serves a cached result.
- A synchronous load is allowed only as a cold-cache fallback guarded by a nil-cache check, or inside the cache's own off-main loader. Such call sites should carry a brief justification comment.

Allowed cases:

- The cache's own background loader (`Task.detached`).
- An explicit cold-cache fallback such as `cache ?? RestorableAgentSessionIndex.load()`.
- Existing call sites the PR does not introduce or worsen.

When reporting, name the heavy loader, the interactive path it now runs on, and the cached/off-main accessor that should replace it.

Background: this rule exists because a synchronous `RestorableAgentSessionIndex.load()` added to the workspace/tab close paths froze the UI 350ms-1.8s on every close (https://github.com/manaflow-ai/cmux/pull/5669).
