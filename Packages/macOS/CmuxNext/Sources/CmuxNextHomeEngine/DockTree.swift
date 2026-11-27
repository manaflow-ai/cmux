import CmuxNextDaemon

/// The slice of the workspace tree the Rust dock ops read (`dock/tree.rs` in cmux-home-rules): built
/// from the live models on the main actor, then sent as JSON.
nonisolated struct DockWorkspace: Encodable, Sendable {
    var kind: String?
    var screens: [DockScreen]

    nonisolated struct DockScreen: Encodable, Sendable {
        var resourceID: String?
        var columns: [DockColumn]
        var panes: [DockPane]
    }

    nonisolated struct DockColumn: Encodable, Sendable {
        var paneIDs: [UInt64]
        var dock: DockEnd?
    }

    nonisolated struct DockEnd: Encodable, Sendable {
        var edge: String
        var role: String
        var isPinned: Bool
        var allowsTabs: Bool
    }

    nonisolated struct DockPane: Encodable, Sendable {
        var handle: UInt64
        var resourceID: String?
        var tabs: [DockTab]
    }

    nonisolated struct DockTab: Encodable, Sendable {
        var id: String
        var surface: UInt64
        var kind: String
        var page: String?
        var conversation: String?
        var hasAgentSession: Bool
        var dead: Bool
        var name: String?
        var hasAgent: Bool
        var commandRunning: Bool
        var hasProgramStatus: Bool
        var hasRelaunch: Bool
        var isRemote: Bool
        var showsUnread: Bool
        var pinned: Bool
        var inTabGroup: Bool
        var cwd: String?
        var title: String
    }
}

extension DockWorkspace {
    @MainActor init(_ workspace: WorkspaceModel) {
        self.init(kind: workspace.kind, screens: workspace.screens.map(DockScreen.init))
    }
}

extension DockWorkspace.DockScreen {
    @MainActor init(_ screen: ScreenModel) {
        self.init(resourceID: screen.resourceID?.rawValue,
                  columns: screen.columns.map(DockWorkspace.DockColumn.init),
                  panes: screen.panes.map(DockWorkspace.DockPane.init))
    }
}

extension DockWorkspace.DockColumn {
    @MainActor init(_ column: ColumnSnapshot) {
        // The rules name the agent chat role `agentChat` (the Swift case name).
        let dock = column.dock.map { dock in
            DockWorkspace.DockEnd(edge: dock.edge.rawValue, role: dock.role == .agentChat ? "agentChat" : "",
                                  isPinned: dock.isPinned, allowsTabs: dock.allowsTabs)
        }
        self.init(paneIDs: column.layout.paneIDs.map(\.rawValue), dock: dock)
    }
}

extension DockWorkspace.DockPane {
    @MainActor init(_ pane: PaneModel) {
        self.init(handle: pane.handle.rawValue, resourceID: pane.resourceID?.rawValue, tabs: pane.tabs.map(DockWorkspace.DockTab.init))
    }
}

extension DockWorkspace.DockTab {
    @MainActor init(_ tab: TabModel) {
        self.init(id: tab.id, surface: tab.surface.rawValue, kind: tab.kind.rawValue, page: tab.page,
                  conversation: tab.snapshot.conversation?.conversation, hasAgentSession: tab.agentSession != nil,
                  dead: tab.dead, name: tab.name, hasAgent: tab.agent != nil, commandRunning: tab.commandSinceMs != nil,
                  hasProgramStatus: !tab.programStatus.isEmpty, hasRelaunch: tab.relaunch != nil, isRemote: tab.remote != nil,
                  showsUnread: tab.showsUnread, pinned: tab.pinned, inTabGroup: tab.tabGroup != nil, cwd: tab.cwd,
                  title: tab.titleText)
    }
}
