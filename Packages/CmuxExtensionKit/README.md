# CmuxExtensionKit

`CmuxExtensionKit` is the prototype API for custom cmux sidebars. A sidebar
provider is pure Swift code that receives a `CmuxExtensionSidebarSnapshot` and
returns a `CmuxExtensionSidebarRenderModel`. The host owns selection, popovers,
window presentation, and mutation dispatch.

State sync has two parts:

1. Bootstrap with `extension.sidebar.snapshot`.
2. Subscribe to `cmux events`.
3. If `CmuxExtensionSidebarReducer.requiresSnapshotReplacement(after:)` returns
   `true`, fetch a fresh `extension.sidebar.snapshot`. Otherwise reduce frames
   with `CmuxExtensionSidebarReducer.reduce(_:event:)`.

That keeps virtualized rows cheap: rows receive immutable render values and
closures, not workspace stores.

```swift
import CmuxExtensionKit

struct MySidebar: CmuxExtensionSidebarProvider {
    let descriptor = CmuxExtensionSidebarProviderDescriptor(
        id: "local.example.sidebar",
        title: .init(key: "local.example.sidebar.title", defaultValue: "Example"),
        subtitle: .init(key: "local.example.sidebar.subtitle", defaultValue: "Local"),
        systemImageName: "folder",
        isHostProvided: false
    )

    func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel {
        let rows = snapshot.workspaces.map { workspace in
            CmuxExtensionSidebarRenderRow(
                id: workspace.id,
                title: workspace.title,
                workspaceId: workspace.id,
                accessory: .inspector
            )
        }
        let section = CmuxExtensionSidebarRenderSection(
            id: "workspaces",
            treeSection: CmuxExtensionWorkspaceTreeSection(
                id: "workspaces",
                title: "Workspaces",
                subtitle: nil,
                systemImageName: "folder",
                projectRootPath: nil,
                workspaceIds: rows.map(\.workspaceId)
            ),
            rows: rows
        )
        return CmuxExtensionSidebarRenderModel(
            providerId: descriptor.id,
            snapshotSequence: snapshot.sequence,
            sections: [section]
        )
    }
}
```

Rows can request host actions through `CmuxExtensionSidebarMutation`, including
workspace selection, worktree creation, persistent section reordering, and
opening popovers or windows. Extension-owned grouping state should be persisted
by the extension, for example in `~/.config/cmux/extensions/<extension>/state.json`.
