# CmuxSidebar

## Workspace topology observation

`WorkspaceSidebarLayoutObservationModel` owns the sidebar's per-workspace
topology invalidation stream. The app owns the workspace and its Bonsplit layout;
the package owns subscription, replay, coalescing, cancellation, and teardown.
Subscribers rebuild an immutable snapshot from the current workspace rather than
maintaining a second copy of its pane layout.

The model can be constructed and tested without launching the app or reading user
preferences:

```swift
@MainActor
func observeLayoutChange() async {
    let model = WorkspaceSidebarLayoutObservationModel()
    var changes = model.changes().makeAsyncIterator()
    model.layoutDidChange()
    let invalidation = await changes.next()
    assert(invalidation != nil)
}
```

Run the focused package tests on a build worker:

```sh
swift test --package-path Packages/macOS/CmuxSidebar \
  --filter WorkspaceSidebarLayoutObservationModelTests
```
