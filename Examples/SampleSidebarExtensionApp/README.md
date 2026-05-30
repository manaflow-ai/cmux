# CMUX Sample Sidebar Extension

This is a standalone macOS app that embeds a CMUX sidebar ExtensionKit app extension. It is the reference project for third-party sidebar authors.

## Build and Enable

1. Open `SampleSidebarExtensionApp.xcodeproj`.
2. Select the app and extension targets.
3. Replace the Manaflow signing team with your own team.
4. Replace the app and extension bundle identifiers with your own reverse-DNS identifiers.
5. Keep the extension point identifier as `com.manaflow.cmux.sidebar`.
6. Keep the ExtensionKit scene identifier as `sidebar`.
7. Build and launch the containing app once.
8. In CMUX, click the titlebar puzzle button, open Sidebar Extensions, and enable the sample.
9. In the same puzzle menu, choose `Extension Sidebar`.
10. If more than one sidebar extension is enabled, choose `CMUX ExtKit Sample Sidebar` inside the hosted sidebar.

The sample targets macOS 26 because it exercises CMUX's current ExtensionFoundation browser and ExtensionKit host path. The `CmuxExtensionKit` data contract is plain Swift and remains separate from that host requirement.

## What It Shows

The extension renders real workspace data supplied by CMUX:

- workspace count
- unread total
- listening port count
- pull request count
- selected workspace
- focus queue based on unread workspaces

It does not use fake workspaces. If CMUX only grants limited access, the sample still renders the metadata CMUX shares by default. After you grant requested access in CMUX, it can also show paths, ports, notifications, and pull request links.

## Authoring Pattern

The sample keeps app-specific state in `SidebarConnectionModel` and delegates XPC plumbing to `CMUXSidebarExtensionConnection`:

```swift
private lazy var extensionConnection = CMUXSidebarExtensionConnection(
    manifest: Self.manifest,
    onSnapshot: { [weak self] snapshot in
        self?.snapshot = snapshot
    },
    onError: { [weak self] message in
        self?.errorText = message
    }
)

func accept(connection: NSXPCConnection) -> Bool {
    extensionConnection.accept(connection)
}
```

The manifest is the permission request CMUX shows to users. Request only the scopes your sidebar actually needs.

## Troubleshooting

If the extension does not appear in CMUX, launch the containing app once, then reopen CMUX's Sidebar Extensions browser.

If it appears but cannot be enabled, check signing on both the containing app and the embedded appex.

If it loads but shows limited information, open the CMUX extension details popover and grant the requested data/actions.
