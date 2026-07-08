# CmuxGit

Reads a directory's git metadata directly from the on-disk repository, with no
`git` subprocess. This is the data behind the workspace sidebar's branch label,
dirty indicator, and (in a later stage) the GitHub pull-request badge.

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
```

The service is stateless and `Sendable`; construct one at the app's composition
root and inject it (e.g. `TabManager(gitMetadataService:)`).

## Testing

All reads are pure functions of the directory argument, so tests run against
real temp directories with hand-written git metadata (no `git` process). The
test target builds fixtures with `GitRepositoryFixture` (writes `HEAD`,
`config`, refs, and working-tree files) and `GitIndexFixture` (writes a binary
`index` for versions 2 and 4, including path prefix-compression). Internal
parsing helpers are exercised via `@testable import CmuxGit`.

```swift
let fixture = try GitRepositoryFixture()
try fixture.writeBranch("main")
let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))

let meta = await GitMetadataService().workspaceMetadata(for: fixture.root.path)
#expect(meta.isDirty == false)
```
