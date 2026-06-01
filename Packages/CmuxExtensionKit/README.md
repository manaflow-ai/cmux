# CMUX Extension Kit

`CmuxExtensionKit` is the zero-dependency public SDK for CMUX sidebar extensions.

Version 1 only supports sidebar extensions. The API exposes a stable workspace snapshot and typed action channels:

- read the current sidebar snapshot
- create, select, navigate, and close workspaces
- create, select, navigate, split, zoom, and close surfaces
- ask CMUX to open a URL

The snapshot includes workspace identity, title, detail text, paths, git branch, unread state, listening ports, pull request URLs, and shared surface metadata. It does not expose terminal buffers, shell history, environment variables, secrets, or arbitrary filesystem access.

Host-side lifecycle, discovery, and display belong in `Packages/CMUXExtensionClient`.

## Five-Minute Sidebar Extension

Sidebar extensions are ExtensionKit app extensions. `CmuxExtensionKit` and the reference projects target macOS 14+, matching CMUX.

Use `Examples/SampleSidebarExtensionApp` as the reference project:

1. Open `SampleSidebarExtensionApp.xcodeproj`.
2. Change the app and extension bundle identifiers to your own reverse-DNS prefix.
3. Change the signing team from Manaflow to your team.
4. Keep the extension point identifier as `com.manaflow.cmux.sidebar`.
5. Build and launch the containing app once so macOS registers the embedded extension.
6. In CMUX, open Sidebar Extensions from the puzzle button next to the sidebar help button and enable your extension.
7. Choose the extension sidebar provider from that puzzle menu.
8. If more than one sidebar extension is enabled, choose your extension from the extension sidebar header.

The extension target declares the extension point manually in its `Info.plist`:

```xml
<key>EXAppExtensionAttributes</key>
<dict>
  <key>EXExtensionPointIdentifier</key>
  <string>com.manaflow.cmux.sidebar</string>
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
    static let manifest = CMUXExtensionManifest(
        id: "dev.example.sidebar",
        displayName: "Example Sidebar",
        requestedScopes: [.workspaceMetadata],
        requestedActionScopes: [.selectWorkspace]
    )

    private(set) var snapshot: CMUXSidebarSnapshot?
    private var host: CmuxSidebarHost?

    required init() {}

    var body: some View {
        List(snapshot?.workspaces ?? []) { workspace in
            Button(workspace.title) {
                Task { @MainActor in
                    _ = await host?.selectWorkspace(workspace.id)
                }
            }
        }
    }

    func update(context: CmuxSidebarContext) {
        snapshot = context.snapshot
        host = context.host
    }
}
```

## Extension Protocols

`CmuxExtension` is the base protocol. It refines `AppExtension` and requires the
manifest CMUX uses for identity, compatibility, and permission review.

`CmuxUIExtension` adds SwiftUI content through a `body` property.

`CmuxSidebarExtension` is the only concrete extension kind supported in version 1. It
delivers `CmuxSidebarContext`, which contains the filtered `CMUXSidebarSnapshot` and a
typed `CmuxSidebarHost` command channel.

The lower-level transport lives behind CMUX host SPI. New sidebar extensions should
conform to `CmuxSidebarExtension` and should not handle XPC directly.

## Permissions

List every scope and action your extension needs in its manifest. CMUX filters the
snapshot and rejects actions that have not been granted:

- `workspaceList`: workspace identities and ordering
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

If your extension does not appear, confirm the containing app has been launched, the embedded appex is signed by your team, the extension point identifier is unchanged, and CMUX's Sidebar Extensions browser shows the extension as enabled.
