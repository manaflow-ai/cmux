# CmuxGit

Reads a directory's Git metadata and workspace changes. Sidebar metadata is
parsed directly from the on-disk repository without a subprocess; mobile
workspace changes use non-locking `/usr/bin/git` commands so committed, staged,
unstaged, untracked, rename, and binary semantics match Git itself.

It is a Layer-2 service package: `Sendable` value facades over filesystem and
process boundaries, with actor isolation only for bounded caches. Its reads are
plain `nonisolated async` methods, which run on the global concurrent executor
(SE-0338) — off the caller's actor and in parallel. It has zero AppKit/SwiftUI
dependencies and is fully testable through injected seams and temp directories.

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

`WorkspaceChangesService` resolves the default branch, compares from its merge
base (or `HEAD` on the default branch), and returns aggregate totals, a capped
file list, or a bounded unified diff. Its summary cache is actor-isolated and
expires entries after 15 seconds by repository root.

## Usage

```swift
let git = GitMetadataService()

let meta = await git.workspaceMetadata(for: checkoutPath)
if meta.isRepository, meta.isDirty { showDirtyDot() }

if let paths = await git.watchedPaths(for: checkoutPath) {
    let watcher = RecursivePathWatcher(paths: paths) // CmuxFileWatch
}

let slugs = await git.repositorySlugs(forDirectory: checkoutPath)

let changes = WorkspaceChangesService()
let summary = await changes.summary(forDirectory: checkoutPath)
let files = await changes.changedFiles(forDirectory: checkoutPath)
let stat = try await changes.fileStat(
    forDirectory: checkoutPath,
    path: "Resources/preview.png",
    revision: .current
)
let firstChunk = try await changes.fileFetch(
    forDirectory: checkoutPath,
    path: "Resources/preview.png",
    revision: .current,
    offset: 0,
    length: 3 * 1024 * 1024
)
```

`GitMetadataService` is stateless and `Sendable`. `WorkspaceChangesService` is
a `Sendable` value facade over its actor-isolated summary cache. Construct these
at the app's composition root and inject or retain them for the owning feature
(e.g. `TabManager(gitMetadataService:)`).

## Testing

All reads are pure functions of the directory argument, so tests run against
real temp directories with hand-written git metadata (no `git` process). The
test target builds fixtures with `GitRepositoryFixture` (writes `HEAD`,
`config`, refs, and working-tree files) and `GitIndexFixture` (writes a binary
`index` for versions 2 and 4, including path prefix-compression). Internal
parsing helpers are exercised via `@testable import CmuxGit`.

Workspace-changes tests inject `WorkspaceChangesGitRunning` and an actor-backed
fake clock for parser/cache unit coverage. Behavior tests create isolated
throwaway repositories under `FileManager.temporaryDirectory` and invoke real
Git commands with a scratch `HOME` and system/global config disabled. Content
tests use the same fixture to verify changed-path authorization, rename/base
selection, stable base materialization, chunk limits, slices, and EOF metadata.

```swift
let fixture = try GitRepositoryFixture()
try fixture.writeBranch("main")
let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))

let meta = await GitMetadataService().workspaceMetadata(for: fixture.root.path)
#expect(meta.isDirty == false)
```
