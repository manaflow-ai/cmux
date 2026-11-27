import Foundation

/// The user-visible features behind server capabilities, in the order a notice names them. A
/// capability with no entry still counts ("and 2 more"); only features a person can see are named.
public nonisolated struct ServerFeatureCatalog: Sendable {
    /// The named features, most notable first.
    public let entries: [ServerFeature]

    /// - Parameter entries: The named features, most notable first.
    public init(entries: [ServerFeature]) {
        self.entries = entries
    }

    /// The named features among `capabilities`, in catalog order.
    public func features(for capabilities: Set<String>) -> [ServerFeature] {
        entries.filter { capabilities.contains($0.capability) }
    }

    /// The catalog the app ships: cmux-tui capabilities the GUI gates on (`DaemonCapability`).
    public static var shipped: ServerFeatureCatalog {
        ServerFeatureCatalog(entries: [
            ServerFeature(capability: "tab-groups-v1", title: UpdaterStrings.text("server.feature.tabGroups", "Tab groups")),
            ServerFeature(capability: "saved-tab-groups-v1", title: UpdaterStrings.text("server.feature.savedTabGroups", "Saved tab groups")),
            ServerFeature(capability: "workspace-groups-v1", title: UpdaterStrings.text("server.feature.workspaceGroups", "Workspace groups")),
            ServerFeature(capability: "workspace-pin-v1", title: UpdaterStrings.text("server.feature.workspacePin", "Pinned workspaces")),
            ServerFeature(capability: "workspace-checklist-v1", title: UpdaterStrings.text("server.feature.workspaceChecklist", "Workspace checklists")),
            ServerFeature(capability: "workspace-description-v1", title: UpdaterStrings.text("server.feature.workspaceDescription", "Workspace descriptions")),
            ServerFeature(capability: "workspace-status-v1", title: UpdaterStrings.text("server.feature.workspaceStatus", "Workspace status")),
            ServerFeature(capability: "browser-profiles-v1", title: UpdaterStrings.text("server.feature.browserProfiles", "Browser profiles")),
            ServerFeature(capability: "bookmarks-v1", title: UpdaterStrings.text("server.feature.bookmarks", "Bookmarks")),
            ServerFeature(capability: "history-v1", title: UpdaterStrings.text("server.feature.history", "History")),
            ServerFeature(capability: "conversation-search-v1", title: UpdaterStrings.text("server.feature.conversationSearch", "Chat search")),
            ServerFeature(capability: "screen-groups-v1", title: UpdaterStrings.text("server.feature.screenGroups", "Screen groups")),
            ServerFeature(capability: "tab-restart-v1", title: UpdaterStrings.text("server.feature.tabRestart", "Restart Tab")),
            ServerFeature(capability: "terminal-command-history-v1", title: UpdaterStrings.text("server.feature.terminalCommandHistory", "Terminal command history")),
        ])
    }
}
