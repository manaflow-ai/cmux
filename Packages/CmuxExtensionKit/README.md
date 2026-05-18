# CmuxExtensionKit

`CmuxExtensionKit` is the prototype API for custom cmux sidebars. A sidebar
provider is pure Swift code that receives a `CmuxExtensionSidebarSnapshot` and
returns a `CmuxExtensionSidebarRenderModel`. The host owns selection, popovers,
window presentation, and mutation dispatch.

State sync has two parts:

1. Bootstrap with `extension.sidebar.snapshot`.
2. Subscribe to `cmux events`, then reduce frames with
   `CmuxExtensionSidebarReducer.reduce(_:event:)`.

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
        mode: .projectTree,
        isHostProvided: false
    )

    func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel {
        CmuxExtensionWorkspaceTreeProvider(descriptor: descriptor)
            .render(snapshot: snapshot)
    }
}
```

Rows can request host actions through `CmuxExtensionSidebarMutation`, including
workspace selection, worktree creation, and opening popovers or windows.
