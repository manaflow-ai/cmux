# CmuxGit

Reads a directory's Git metadata and workspace changes. Sidebar metadata parses
file-backed refs directly and uses bounded Git plumbing for other reference
backends such as reftable. Workspace changes use non-locking, bounded Git
commands so committed, staged, unstaged, untracked, rename, and binary
semantics match Git itself.

It is a Layer-2 service package: `Sendable` value facades over filesystem and
process boundaries, with actor isolation only for bounded caches. Its reads are
plain `nonisolated async` methods, which run on the global concurrent executor
(SE-0338) — off the caller's actor and in parallel. It has zero AppKit/SwiftUI
dependencies and is fully testable through injected seams and temp directories.

## What it does

`GitMetadataService` resolves the repository enclosing a directory (handling
`.git` files for worktrees/submodules and the shared `commondir`), resolves
`HEAD`, and parses the binary `index` (v2/v3/v4) and `config` (following
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

`SystemGitHeadContentReader` conforms to `GitHeadContentReading` and returns a
file's bytes as committed at `HEAD`, plus the repository paths whose changes
can move that content: `HEAD`, `index`, the checked-out branch's loose ref,
`packed-refs`, and `reftable`. It reads `HEAD` rather than the merge base, which is what an
editor gutter needs, and returns bytes so the caller decodes them with the
working copy's encoding. Symbolic links resolve to their target, then
`git cat-file blob HEAD:./name` runs from the file's directory, so no
repository-root lookup is needed and no textconv filter applies. Untracked
files, files outside a repository, and content over 2 MiB return `nil`.

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
let head: any GitHeadContentReading = SystemGitHeadContentReader()
let base = await head.headContent(forFile: "/repo/Sources/App.swift")
let watched = await head.watchedPaths(forFile: "/repo/Sources/App.swift")

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

File-backed reads are deterministic for a stable fixture, so most tests run
against real temp directories with hand-written Git metadata. The test
target builds fixtures with `GitRepositoryFixture` (writes `HEAD`, `config`,
refs, and working-tree files) and `GitIndexFixture` (writes a binary `index` for
versions 2 and 4, including path prefix-compression). Reftable behavior uses an
isolated throwaway repository created with `/usr/bin/git`, exercising the same
plumbing boundary as production. Internal parsing helpers are exercised via
`@testable import CmuxGit`.

Workspace-changes tests inject `WorkspaceChangesGitRunning` and an actor-backed
fake clock for parser/cache unit coverage. Behavior tests create isolated
throwaway repositories under `FileManager.temporaryDirectory` and invoke real
Git commands with a scratch `HOME` and system/global config disabled. Content
tests use the same fixture to verify changed-path authorization, rename/base
selection, stable base materialization, chunk limits, slices, and EOF metadata.
`SystemGitHeadContentReader` tests use the same fixture and inject a small
content budget to cover the size limit. Consumers depend on
`GitHeadContentReading` and substitute a fixed-content fake.

```swift
let fixture = try GitRepositoryFixture()
try fixture.writeBranch("main")
let entry = try fixture.writeWorkingTreeFile("file.txt", contents: "hello")
try fixture.writeIndex(GitIndexFixture(version: 2, entries: [entry]))

let meta = await GitMetadataService().workspaceMetadata(for: fixture.root.path)
#expect(meta.isDirty == false)
```
