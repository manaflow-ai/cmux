# CmuxFileTree

`CmuxFileTree` is the model behind the right sidebar Files tree. It has no
AppKit dependency and owns everything that should not run on the main actor:

- `FileTreeProvider`: one protocol for this Mac, SSH hosts and Cloud VMs. It
  lists directories (with a batch call so SSH restores expanded folders in one
  round trip) and optionally streams change batches.
- `LocalFileTreeProvider`: `getattrlistbulk(2)` listing and one FSEvents stream
  per root.
- `FileTreeEngine`: an actor that caches raw listings, sorts and filters them,
  drops superseded loads and delivers `FileTreeChildrenDiff` values shaped for
  `NSOutlineView` batch updates.
- `FileTreeSortOrder`: Finder-like natural name order plus kind, date and size.

Tests inject a scripted provider; no test touches `UserDefaults.standard` or the
user's files:

```swift
let engine = FileTreeEngine(provider: LocalFileTreeProvider())
let updates = await engine.load([temporaryDirectory.path])
```

```bash
swift test --package-path Packages/macOS/CmuxFileTree
swift test --package-path Packages/macOS/CmuxFileTree -c release -Xswiftc -enable-testing \
  --filter FileTreePerformanceBenchmarkTests   # 50k-entry benchmark numbers
```
