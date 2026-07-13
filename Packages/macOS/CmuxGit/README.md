# CmuxGit

Reads Git metadata for cmux workspaces. Sidebar metadata is parsed directly from
the on-disk repository; mobile status and unified-diff payloads use system Git
plumbing through an injected command runner.

It is a Layer-2 service package: a stateless `Sendable` value over pure parsing
helpers. Its reads are plain `nonisolated async` methods, which run on the global
concurrent executor (SE-0338) — off the caller's actor and in parallel — with no
actor serialization, since there is no shared state to protect. Zero AppKit/SwiftUI
dependencies, fully testable against temp directories.

## What it does

`GitMetadataService` resolves the repository enclosing a directory (handling
`.git` files for worktrees/submodules and the shared `commondir`) and parses
`HEAD`, the binary `index` (v2/v3/v4), and `config` (following
`include`/`includeIf`). From that it derives:

- `workspaceMetadata(for:)` — branch, dirty state, and change-detection
  signatures (`GitWorkspaceMetadata`).
- `watchedPaths(for:)` — the existing paths a filesystem watcher should observe
  to know when that metadata goes stale (including submodule gitlinks).
- `repositorySlugs(forDirectory:)` — the GitHub `owner/name` remotes, ordered
  `upstream`, `origin`, then the rest.
- `WorkspaceGitService.status(forDirectory:)` — staged, unstaged, and untracked
  files relative to `HEAD`, with rename-aware numstat counts.
- `WorkspaceGitService.diff(forDirectory:paths:byteCap:)` — per-path unified
  patches with deterministic truncation and individually oversized-path metadata.

Dirty detection mirrors git's stat-based check (size/mode/mtime per tracked
entry, plus submodule-commit comparison for gitlinks), and excludes
assume-unchanged and skip-worktree entries.

## Usage

```swift
let git = GitMetadataService()

let meta = await git.workspaceMetadata(for: checkoutPath)
if meta.isRepository, meta.isDirty { showDirtyDot() }

if let paths = await git.watchedPaths(for: checkoutPath) {
    let watcher = RecursivePathWatcher(paths: paths) // CmuxFileWatch
}

let slugs = await git.repositorySlugs(forDirectory: checkoutPath)

let mobileGit = WorkspaceGitService()
let status = try await mobileGit.status(forDirectory: checkoutPath)
let diff = try await mobileGit.diff(
    forDirectory: checkoutPath,
    paths: status.files.map(\.path)
)
```

The service is stateless and `Sendable`; construct one at the app's composition
root and inject it (e.g. `TabManager(gitMetadataService:)`).

## Testing

`GitMetadataService` reads are pure functions of the directory argument, so its
tests run against real temp directories with hand-written git metadata (no
`git` process). The test target builds fixtures with `GitRepositoryFixture` (writes `HEAD`,
`config`, refs, and working-tree files) and `GitIndexFixture` (writes a binary
`index` for versions 2 and 4, including path prefix-compression). Internal
parsing helpers are exercised via `@testable import CmuxGit`.

`WorkspaceGitService` takes `any CommandRunning` in its initializer so service
tests can inject captured porcelain, numstat, and patch output without spawning
Git. The NUL-delimited parser and diff-cap accumulator are pure internal types
covered directly by the package test target.

```swift
let fixture = try GitRepositoryFixture()
try fixture.writeBranch("main")
let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))

let meta = await GitMetadataService().workspaceMetadata(for: fixture.root.path)
#expect(meta.isDirty == false)
```
