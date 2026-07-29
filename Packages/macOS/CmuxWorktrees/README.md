# CmuxWorktrees

`CmuxWorktrees` exposes Git worktrees without introducing a cmux-owned
lifecycle. Git remains the source of truth: listing always reads
`git worktree list --porcelain`, and mutations use ordinary Git commands.

The service is stateless and every operation receives an execution host. The
local host wraps an injected `CommandRunning`; a future SSH host can implement
the same protocol without changing worktree identities or callers.

```swift
let service = WorktreeService()
let host = LocalWorktreeExecutionHost()
let worktrees = try await service.list(repoRoot: "/repo", on: host)
```

Tests use real temporary Git repositories and may also inject a host or command
runner to exercise unavailable-host and command-failure boundaries.
