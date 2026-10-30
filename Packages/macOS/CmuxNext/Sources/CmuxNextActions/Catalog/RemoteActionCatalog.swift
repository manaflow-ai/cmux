// Catalog rows for one domain. Titles live in ActionCatalog.xcstrings.

/// cmux Remote (docs/cmux-remote.md): the one process that holds the grants for Computer Use
/// and Screen Sharing, and this Mac's Screen Sharing switches. The CLI and MCP also reach the
/// host through the daemon (`cmux remote-host`, `remote_*` tools), with the app quit too.
nonisolated enum RemoteActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "remote.showStatus",
                title: String(localized: "action.remote.showStatus", defaultValue: "cmux Remote: Show Status", bundle: .module),
                keywords: ["cmux remote", "screen sharing", "computer use", "permissions", "accessibility", "screen recording", "status"],
                category: .tab, symbol: "display.and.arrow.down", surfaces: [.palette],
                cliName: "remote show-status",
                surfacePlan: ActionSurfacePlan(contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "remote.refreshPermissions",
                title: String(localized: "action.remote.refreshPermissions", defaultValue: "cmux Remote: Refresh Permissions", bundle: .module),
                keywords: ["cmux remote", "permissions", "accessibility", "screen recording", "grant", "refresh", "tcc"],
                category: .tab, symbol: "arrow.clockwise", surfaces: [.palette],
                cliName: "remote refresh-permissions",
                surfacePlan: ActionSurfacePlan(contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "remote.allowAccessibility",
                title: String(localized: "action.remote.allowAccessibility", defaultValue: "cmux Remote: Allow Accessibility", bundle: .module),
                keywords: ["cmux remote", "accessibility", "permission", "grant", "tcc", "computer use", "screen sharing"],
                category: .tab, symbol: "accessibility", surfaces: [.palette],
                cliName: "remote allow-accessibility",
                surfacePlan: ActionSurfacePlan(contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "remote.allowScreenRecording",
                title: String(localized: "action.remote.allowScreenRecording", defaultValue: "cmux Remote: Allow Screen Recording", bundle: .module),
                keywords: ["cmux remote", "screen recording", "permission", "grant", "tcc", "computer use", "screen sharing"],
                category: .tab, symbol: "record.circle", surfaces: [.palette],
                cliName: "remote allow-screen-recording",
                surfacePlan: ActionSurfacePlan(contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "remote.restartComputerUse",
                title: String(localized: "action.remote.restartComputerUse", defaultValue: "cmux Remote: Restart Computer Use", bundle: .module),
                keywords: ["cmux remote", "computer use", "restart", "worker", "agents"],
                category: .tab, symbol: "arrow.clockwise.circle", surfaces: [.palette],
                cliName: "remote restart-computer-use",
                surfacePlan: ActionSurfacePlan(contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "remote.restartScreenSharing",
                title: String(localized: "action.remote.restartScreenSharing", defaultValue: "cmux Remote: Restart Screen Sharing", bundle: .module),
                keywords: ["cmux remote", "screen sharing", "mac screen", "restart", "worker"],
                category: .tab, symbol: "arrow.clockwise.circle", surfaces: [.palette],
                cliName: "remote restart-screen-sharing",
                surfacePlan: ActionSurfacePlan(contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "macScreen.shareThisMac",
                title: String(localized: "action.macScreen.shareThisMac", defaultValue: "Share This Mac", bundle: .module),
                keywords: ["mac", "screen", "sharing", "share", "allow", "device", "remote", "iphone"],
                category: .tab, symbol: "display", surfaces: [.palette],
                cliName: "remote share-this-mac",
                surfacePlan: ActionSurfacePlan(contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "macScreen.stopSharingThisMac",
                title: String(localized: "action.macScreen.stopSharingThisMac", defaultValue: "Turn Off Sharing This Mac", bundle: .module),
                keywords: ["mac", "screen", "sharing", "stop", "off", "disable", "device", "remote"],
                category: .tab, symbol: "display.trianglebadge.exclamationmark", surfaces: [.palette],
                cliName: "remote stop-sharing-this-mac",
                surfacePlan: ActionSurfacePlan(contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "macScreen.deviceAccess",
                title: String(localized: "action.macScreen.deviceAccess", defaultValue: "Set Device Access to This Mac…", bundle: .module),
                keywords: ["mac", "screen", "sharing", "device", "access", "permission", "view", "full control", "ask", "none"],
                category: .tab, symbol: "person.badge.key", surfaces: [.palette],
                cliName: "remote device-access",
                surfacePlan: ActionSurfacePlan(contextMenuExemption: .noObject)
            ),
        ]
    }
}
