# CMUX Sample Sidebar Extension

This is a standalone macOS app that embeds a CMUX sidebar ExtensionKit app extension. It is the reference project for third-party sidebar authors.

## Build and Enable

1. Open `SampleSidebarExtensionApp.xcodeproj`.
2. Select the app and extension targets.
3. Replace the Manaflow signing team with your own team.
4. Replace the app and extension bundle identifiers with your own reverse-DNS identifiers.
5. Keep the extension point identifier as `com.cmuxterm.app.cmux.sidebar`.
6. Keep App Sandbox enabled for the extension target. An unsandboxed appex can
   build, embed, and sign without registering with ExtensionKit.
7. Build and launch the containing app once.
8. In CMUX, click the puzzle button next to the sidebar help button, open Sidebar
   Extensions, and enable the sample.
9. In the same puzzle menu, choose the extension sidebar provider.
10. In the extension sidebar header, choose `CMUX ExtKit Sample Sidebar` if more
    than one sidebar extension is enabled.

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
    static let manifest = CmuxExtensionManifest(...)
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
    private(set) var snapshot: CmuxSidebarSnapshot?
    private var host: CmuxSidebarHost?

    func update(context: CmuxSidebarContext) {
        snapshot = context.snapshot
        host = context.host
    }

    func selectWorkspace(_ id: UUID) async {
        try? await host?.selectWorkspace(id)
    }

    func selectNextWorkspace() async {
        try? await host?.selectNextWorkspace()
    }

    func createTerminalSurface(in workspaceID: UUID?) async {
        try? await host?.createTerminalSurface(in: workspaceID)
    }
}
```

`CmuxSidebarExtension` owns the ExtensionKit scene and XPC connection, so extension
authors do not define `configuration`, bind an extension point in Swift, or touch
`NSXPCConnection`.

`CmuxSidebarContext` exposes one typed host channel through `context.host`.

The manifest is the permission request CMUX shows to users. Request only the scopes
your sidebar actually needs.

## Running External Tools

CMUX read scopes can supply a workspace path, but they do not grant filesystem
access to that path. A compiled extension that launches `git` or another
external process must also satisfy the macOS App Sandbox, executable resolution,
working-directory, and file-privacy rules. Follow the SDK's
[Running external tools](../../Packages/macOS/CmuxExtensionKit/README.md#running-external-tools)
guide before adding `Process` code.

## Troubleshooting

If the extension does not appear in CMUX, confirm that App Sandbox is enabled for
the extension target, launch the containing app once, then reopen CMUX's Sidebar
Extensions browser. You can also check system discovery directly:

```sh
pluginkit -mAvvv
```

The normal CMUX release uses `com.cmuxterm.app.cmux.sidebar`. Tagged development
builds use the point stored in the host's `CMUXSidebarExtensionPointIdentifier`
Info.plist key (currently `<host-bundle-id>.cmux.sidebar`), so do not filter on
the production point when diagnosing a tagged or custom host.

If it appears but cannot be enabled, check signing on both the containing app and the embedded appex.

If it loads but row clicks do not select workspaces, open the CMUX extension details popover and grant the requested action.
