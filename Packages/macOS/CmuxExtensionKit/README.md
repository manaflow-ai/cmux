# CMUX Extension Kit

`CmuxExtensionKit` is the zero-dependency public SDK for CMUX sidebar extensions.

Version 1 only supports sidebar extensions. The API exposes a stable workspace snapshot and typed action channels:

- read the current sidebar snapshot
- create, select, navigate, and close workspaces
- create, select, navigate, split, zoom, and close surfaces
- ask CMUX to open a URL
- run workspace commands the user already defined in `cmux.json`
- invoke the configured `ui.newWorkspace.action` for a workspace directory

The snapshot includes workspace identity, title, detail text, paths, git branch, unread state, listening ports, pull request URLs, and shared surface metadata. It does not expose terminal buffers, shell history, environment variables, secrets, or arbitrary filesystem access.

Host-side lifecycle, discovery, and display belong in `Packages/macOS/CMUXExtensionHostSupport`.
Internal cmux-owned sidebar provider/render models live in `Packages/macOS/CmuxSidebarProviderKit`.
They are separate from the public extension-author SDK.

## Five-Minute Sidebar Extension

Sidebar extensions are ExtensionKit app extensions. `CmuxExtensionKit` and the reference projects target macOS 14+, matching CMUX.

Use `Examples/SampleSidebarExtensionApp` as the reference project:

1. Open `SampleSidebarExtensionApp.xcodeproj`.
2. Change the app and extension bundle identifiers to your own reverse-DNS prefix.
3. Change the signing team from Manaflow to your team.
4. Keep the extension point identifier as `com.cmuxterm.app.cmux.sidebar`.
5. Build and launch the containing app once so macOS registers the embedded extension.
6. In CMUX, open Sidebar Extensions from the puzzle button next to the sidebar help button and enable your extension.
7. Choose the extension sidebar provider from that puzzle menu.
8. If more than one sidebar extension is enabled, choose your extension from the extension sidebar header.

The extension target declares the extension point manually in its `Info.plist`:

```xml
<key>EXAppExtensionAttributes</key>
<dict>
  <key>EXExtensionPointIdentifier</key>
  <string>com.cmuxterm.app.cmux.sidebar</string>
</dict>
```

Define your ExtensionKit entrypoint by conforming directly to `CmuxSidebarExtension`.
The SDK refines `ExtensionFoundation.AppExtension`, supplies the ExtensionKit
configuration, owns the scene/XPC wiring, and uses the stable sidebar scene ID.
Your extension provides the manifest, SwiftUI view, and update handling:

```swift
import CmuxExtensionKit
import Observation
import SwiftUI

@main
@Observable
@MainActor
final class ExampleSidebarExtension: CmuxSidebarExtension {
    static let manifest = CmuxExtensionManifest(
        id: "dev.example.sidebar",
        displayName: String(localized: "exampleSidebar.manifest.displayName", defaultValue: "Example Sidebar"),
        readScopes: [.workspaceMetadata],
        actionScopes: [.selectWorkspace]
    )

    private(set) var snapshot: CmuxSidebarSnapshot?
    private var host: CmuxSidebarHost?

    required init() {}

    var body: some View {
        List(snapshot?.workspaces ?? []) { workspace in
            Button(workspace.title) {
                Task { @MainActor in
                    try? await host?.selectWorkspace(workspace.id)
                }
            }
        }
    }

    func update(context: CmuxSidebarContext) {
        snapshot = context.snapshot
        host = context.host
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {
        // Update optional connection UI here.
    }
}
```

## Extension Protocols

`CmuxSidebarExtension` is the public extension protocol. It refines `AppExtension`,
requires a manifest and SwiftUI `body`, and delivers `CmuxSidebarContext`, which
contains the filtered `CmuxSidebarSnapshot` and a typed `CmuxSidebarHost` command
channel.

The lower-level transport lives behind CMUX host SPI. New sidebar extensions should
conform to `CmuxSidebarExtension` and should not handle XPC directly.

`connectionStatusDidChange(_:)` reports `.connected`, `.waitingForHost`, or
`.error(String)` when the host connection changes. Extensions that do not show
connection state can omit the method.

`context.host` is the public command channel for sidebar extensions. It exposes
typed helpers for workspace, surface, and URL actions. Raw transport setup and
host-side callbacks are SPI for CMUX's own host implementation.
Creating or splitting a browser surface with a URL requires both the surface
action scope and `openURL`.
Running a workspace command uses only a command name or action identifier; CMUX
resolves the user-authored `cmux.json` command host-side and never accepts shell
text from the extension. Passing a working directory asks CMUX to resolve the
nearest local config for that path and also requires `createWorkspaceWithPath`.
`invokeNewWorkspaceAction(workingDirectory:)` uses the same permission scope and
resolves `ui.newWorkspace.action` from `cmux.json` for the requested directory.

## Permissions

List every scope and action your extension needs in its manifest. CMUX filters the
snapshot and rejects actions that have not been granted:

- `workspaceList`: workspace identities and ordering only
- `workspaceMetadata`: workspace names, branches, unread counts, and selection
- `surfaceMetadata`: shared tab/surface names, kinds, focus, and unread counts
- `workspacePaths`: local workspace and project paths
- `notifications`: latest workspace notifications
- `networkPorts`: listening ports for each workspace
- `pullRequests`: pull request links associated with workspaces
- `createWorkspace`: create workspaces
- `selectWorkspace`: select a workspace from your UI
- `closeWorkspace`: close workspaces from your UI
- `createSurface`: create terminal and browser surfaces
- `selectSurface`: select a surface within a workspace
- `closeSurface`: close a surface
- `splitSurface`: split a terminal or browser surface
- `zoomSurface`: toggle surface zoom
- `navigateWorkspace`: select the next or previous workspace
- `navigateSurface`: select the next or previous surface
- `openURL`: open links from your UI
- `createWorkspaceWithPath`: create workspaces for specific local folders
- `runWorkspaceCommand`: run workspace commands the user defined in `cmux.json`
  or invoke the configured `ui.newWorkspace.action`

If your extension does not appear, confirm the containing app has been launched, the embedded appex is signed by your team, the extension point identifier is unchanged, and CMUX's Sidebar Extensions browser shows the extension as enabled.
