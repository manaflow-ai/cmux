# CmuxPanes

Owns pane navigation, split geometry, and persisted pane layout restoration.
`SessionSplitContainerLayoutCodec` takes a `BonsplitController` from its owner;
creating or closing app panels stays in the owning workspace or Dock.

A package test can create the codec without launching the cmux app:

```swift
let controller = BonsplitController()
let codec = SessionSplitContainerLayoutCodec(controller: controller)
let layout = codec.snapshot { tabID in panelIDsByTabID[tabID] }
let restored = codec.restoreExistingLayout(
    layout,
    panelIDMap: oldToNewPanelIDs,
    tabIDForPanelID: { tabIDsByPanelID[$0] }
)
```

The controller calls its delegate synchronously. The app owner must enter its
programmatic split scope before restoring, so inert tabs do not trigger user
split callbacks that create terminal panels. Full-layout replay declines before
mutation when the current tree contains a tab absent from the saved layout.

`SessionWorkspaceLayoutSnapshot.remappingPanelIDs` transforms immutable values
without actor isolation. Its Codable layout remains compatible with existing
session and closed-history files, including missing full-width tab fields.

Run the package tests with `swift test --package-path Packages/macOS/CmuxPanes`.
