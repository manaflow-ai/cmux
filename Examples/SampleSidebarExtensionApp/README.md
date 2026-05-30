# CMUX Sample Sidebar Extension

This is a standalone macOS app that embeds a CMUX sidebar ExtensionKit app extension. It is the reference project for third-party sidebar authors.

## Build and Enable

1. Open `SampleSidebarExtensionApp.xcodeproj`.
2. Select the app and extension targets.
3. Replace the Manaflow signing team with your own team.
4. Replace the app and extension bundle identifiers with your own reverse-DNS identifiers.
5. Keep the extension point identifier as `com.manaflow.cmux.sidebar`.
6. Build and launch the containing app once.
7. In CMUX, click the puzzle button next to the sidebar help button, open Sidebar Extensions, and enable the sample.
8. In the same puzzle menu, choose the extension sidebar provider.
9. In the extension sidebar header, choose `CMUX ExtKit Sample Sidebar` if more than one sidebar extension is enabled.

The sample targets macOS 14+, matching CMUX.

## What It Shows

The extension renders real workspace data supplied by CMUX:

- workspace count
- unread total
- pinned workspace count
- all shared workspaces
- selected workspace
- each workspace's shared surfaces
- focused surface indicators
- compact focus summary based on workspace signals

It does not use fake workspaces. The sample requests workspace metadata, surface metadata, and the action permissions needed for its controls: selecting workspaces, selecting surfaces, moving to the previous or next workspace or surface, and creating a terminal surface.

## Authoring Pattern

The sample's `@main` ExtensionKit entrypoint conforms directly to
`CmuxSidebarExtension`. App-specific state lives in `SidebarConnectionModel`. CMUX
delivers workspace updates through `update(context:)`, and the model uses the typed
host helpers for actions:

```swift
@main
@MainActor
final class SampleSidebarExtension: CmuxSidebarExtension {
    static let manifest = CMUXExtensionManifest(...)
    private let model = SidebarConnectionModel()

    required init() {}

    var body: some View {
        SampleSidebarView(model: model)
    }

    func update(context: CmuxSidebarContext) {
        model.update(context: context)
    }
}

@Observable
@MainActor
final class SidebarConnectionModel {
    private(set) var snapshot: CMUXSidebarSnapshot?
    private var host: CmuxSidebarHost?
    private var cmux: CmuxHost?

    func update(context: CmuxSidebarContext) {
        snapshot = context.snapshot
        host = context.host
        cmux = context.cmux
    }

    func selectWorkspace(_ id: UUID) {
        Task { @MainActor in
            _ = await host?.selectWorkspace(id)
        }
    }

    func selectNextWorkspace() {
        Task { @MainActor in
            _ = await cmux?.selectNextWorkspace()
        }
    }

    func createTerminalSurface(in workspaceID: UUID?) {
        Task { @MainActor in
            _ = await host?.createTerminalSurface(in: workspaceID)
        }
    }
}
```

`CmuxSidebarExtension` owns the ExtensionKit scene and XPC connection, so extension
authors do not define `configuration`, bind an extension point in Swift, or touch
`NSXPCConnection`.

`CmuxSidebarContext` exposes two typed host channels:

- `context.cmux` for generic CMUX actions that are useful across extension types.
- `context.host` for sidebar-specific actions that operate on sidebar snapshot data.

The manifest is the permission request CMUX shows to users. Request only the scopes
your sidebar actually needs.

## Troubleshooting

If the extension does not appear in CMUX, launch the containing app once, then reopen CMUX's Sidebar Extensions browser.

If it appears but cannot be enabled, check signing on both the containing app and the embedded appex.

If it loads but row clicks do not select workspaces, open the CMUX extension details popover and grant the requested action.
