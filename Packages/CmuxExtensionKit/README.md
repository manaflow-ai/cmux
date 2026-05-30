# CMUX Extension Kit

`CmuxExtensionKit` is the zero-dependency public contract for CMUX sidebar extensions.

Version 1 only supports sidebar extensions. The API exposes a stable workspace snapshot and a small action channel:

- read the current sidebar snapshot
- select a workspace
- close a workspace
- ask CMUX to open a URL

The snapshot intentionally starts small: workspace identity, title, detail text, paths, git branch, unread state, listening ports, and pull request URLs. It does not expose terminal buffers, shell history, environment variables, secrets, or arbitrary filesystem access.

Host-side lifecycle, discovery, and display belong in `Packages/CMUXExtensionClient`.

## Five-Minute Sidebar Extension

Sidebar extensions are ExtensionKit app extensions. The package itself supports macOS 14+ because the data contract is plain Swift, but CMUX currently discovers and enables third-party sidebar app extensions through ExtensionFoundation and ExtensionKit on macOS 26.

Use `Examples/SampleSidebarExtensionApp` as the reference project:

1. Open `SampleSidebarExtensionApp.xcodeproj`.
2. Change the app and extension bundle identifiers to your own reverse-DNS prefix.
3. Change the signing team from Manaflow to your team.
4. Keep the extension point identifier as `com.manaflow.cmux.sidebar`.
5. Keep the scene identifier as `sidebar`.
6. Build and launch the containing app once so macOS registers the embedded extension.
7. In CMUX, open Sidebar Extensions from the titlebar puzzle button and enable your extension.
8. Choose the extension as the active sidebar provider.

The extension target declares the extension point manually in its `Info.plist`:

```xml
<key>EXAppExtensionAttributes</key>
<dict>
  <key>EXExtensionPointIdentifier</key>
  <string>com.manaflow.cmux.sidebar</string>
</dict>
```

Your extension view accepts CMUX's XPC connection and hands it to the kit helper:

```swift
let sidebarConnection = CMUXSidebarExtensionConnection(
    manifest: CMUXExtensionManifest(
        id: "dev.example.sidebar",
        displayName: "Example Sidebar",
        requestedScopes: [.workspaceMetadata],
        requestedActionScopes: [.selectWorkspace]
    ),
    onSnapshot: { snapshot in
        // Render real CMUX workspace data.
    },
    onError: { message in
        // Show or clear extension-local error state.
    }
)

func accept(connection: NSXPCConnection) -> Bool {
    sidebarConnection.accept(connection)
}
```

CMUX grants only workspace metadata by default. Anything else must be listed in the manifest and approved in CMUX:

- `workspaceMetadata`: workspace names, branches, unread counts, and selection
- `workspacePaths`: local workspace and project paths
- `notifications`: latest workspace notifications
- `networkPorts`: listening ports for each workspace
- `pullRequests`: pull request links associated with workspaces
- `selectWorkspace`: select a workspace from your UI
- `closeWorkspace`: close workspaces from your UI
- `openURL`: open links from your UI

If your extension does not appear, confirm the containing app has been launched, the embedded appex is signed by your team, the extension point identifier is unchanged, and CMUX's Sidebar Extensions browser shows the extension as enabled.
