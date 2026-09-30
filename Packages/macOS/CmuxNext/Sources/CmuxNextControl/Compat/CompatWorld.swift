import CmuxNextDaemon
import Foundation

/// One immutable view of everything the old CLI can name: the daemon tree
/// (fetched fresh per request, so a read that follows a write sees it) joined
/// with the App's frontend snapshot, with old-app UUIDs, refs, and indexes.
/// Built off the main actor; never mutated.
struct CompatWorld: Sendable {
    /// One federated cmux-tui session (`ControlSessionInfo`).
    struct Session: Sendable, Hashable {
        var id: String
        var qualifier: String
        var machineID: String
        var machineName: String?
        var sessionName: String?
        var isHome: Bool
        var state: String
        var transport: String
    }

    struct Window: Sendable {
        var uuid: String
        var ref: String
        var index: Int
        var modelID: String
        var workspaceUUID: String?
        /// Every workspace the window lists.
        var workspaceUUIDs: [String] = []
        var isKey: Bool
        var isVisible: Bool
        /// Kept off screen by the app (`ControlWindowInfo.isHidden`).
        var isHidden = false
        /// The workspaces its sidebar shows now (current room, reported by a machine).
        var visibleWorkspaceUUIDs: [String] = []
    }

    struct Workspace: Sendable {
        var uuid: String
        var ref: String
        var index: Int
        var modelID: String
        var key: WorkspaceKey?
        var handle: WorkspaceHandle
        var name: String
        var title: String
        var customTitle: String?
        var color: String?
        var icon: String?
        var group: String?
        var unreadCount: Int
        var paneUUIDs: [String]
        var surfaceUUIDs: [String]
        var focusedPaneUUID: String?
        /// Windows showing this workspace.
        var windowUUIDs: [String]
        /// Its home session (`Session.id`); nil for the app's home session.
        var sessionID: String? = nil
        /// That session (the home session's record for home objects; nil
        /// when the topology reports no sessions).
        var session: Session? = nil
    }

    struct Pane: Sendable {
        var uuid: String
        var ref: String
        var index: Int
        var modelID: String
        var handle: PaneID
        var workspaceUUID: String
        var screenIndex: Int
        var name: String?
        var surfaceUUIDs: [String]
        var selectedSurfaceUUID: String?
        var focused: Bool
        var zoomed: Bool
        /// The session whose daemon owns the pane's handle (nil: home).
        var sessionID: String? = nil
        var session: Session? = nil
    }

    struct Surface: Sendable {
        var uuid: String
        var ref: String
        var index: Int
        var indexInPane: Int
        var modelID: String
        var handle: SurfaceID
        var paneUUID: String
        var workspaceUUID: String
        var tab: Tab
        var selected: Bool
        var focused: Bool
        /// The session whose daemon owns the surface's handle (nil: home).
        var sessionID: String? = nil
        var session: Session? = nil

        var isTerminal: Bool { tab.kind == "terminal" }
        var isBrowser: Bool { tab.kind == "browser" }
        var typeName: String { tab.kind }
        var title: String { tab.title }
    }

    /// What the CLI needs of a tab (from `ControlTabInfo`).
    struct Tab: Sendable {
        var kind: String
        var title: String
        var terminalID: String?
        var cwd: String?
        var url: String?
        var gitBranch: String?
        var pinned: Bool
        var dead: Bool
        var unread: Bool
    }

    var windows: [Window] = []
    /// Every session, the home session first.
    var sessions: [Session] = []
    /// The session unqualified refs, indexes, lists and creation address
    /// (the request's `session` param); nil is the home session.
    var scope: Session?
    var workspaces: [Workspace] = []
    var panes: [String: Pane] = [:]
    var surfaces: [String: Surface] = [:]
    /// The window commands act on by default.
    var activeWindowUUID: String?
    var generation: String?

    var activeWindow: Window? { windows.first { $0.uuid == activeWindowUUID } ?? windows.first { !$0.isHidden } }

    /// The windows the user sees; every window with `includeHidden`.
    func listedWindows(includeHidden: Bool) -> [Window] {
        includeHidden ? windows : windows.filter { !$0.isHidden }
    }

    /// The session `id` names; nil for the home session.
    func session(_ id: String?) -> Session? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    /// The session scope as a session id (nil: home).
    var scopeID: String? { scope.flatMap { $0.isHome ? nil : $0.id } }

    /// Workspaces of the scope session, in world order; every workspace
    /// when the request names no session.
    var scopedWorkspaces: [Workspace] {
        guard let scope else { return workspaces }
        return workspaces.filter { $0.sessionID == (scope.isHome ? nil : scope.id) }
    }

    func workspace(_ uuid: String?) -> Workspace? {
        guard let uuid else { return nil }
        return workspaces.first { $0.uuid == uuid }
    }

    func window(_ uuid: String?) -> Window? {
        guard let uuid else { return nil }
        return windows.first { $0.uuid == uuid }
    }

    func orderedPanes(in workspace: Workspace) -> [Pane] { workspace.paneUUIDs.compactMap { panes[$0] } }
    func orderedSurfaces(in workspace: Workspace) -> [Surface] { workspace.surfaceUUIDs.compactMap { surfaces[$0] } }
    func orderedSurfaces(in pane: Pane) -> [Surface] { pane.surfaceUUIDs.compactMap { surfaces[$0] } }

    /// The workspaces `window` lists (each workspace belongs to one window),
    /// in world order. Every workspace for no window, or for a topology
    /// that carries no membership.
    /// Only workspaces of the scope session when the request names one.
    func workspaces(in window: Window?) -> [Workspace] {
        guard let window, !window.workspaceUUIDs.isEmpty else { return scopedWorkspaces }
        let members = Set(window.workspaceUUIDs)
        return scopedWorkspaces.filter { members.contains($0.uuid) }
    }

    /// The workspace a window shows, else the first one. With a session
    /// scope: the shown one when it is on that session, else the window's
    /// first workspace there, else the session's first.
    func currentWorkspace(window: Window?) -> Workspace? {
        guard scope != nil else { return workspace(window?.workspaceUUID) ?? workspaces.first }
        let inScope = scopedWorkspaces
        if let shown = workspace(window?.workspaceUUID), inScope.contains(where: { $0.uuid == shown.uuid }) { return shown }
        return workspaces(in: window).first ?? inScope.first
    }

    /// Focused pane and surface of a workspace.
    func focus(in workspace: Workspace) -> (pane: Pane?, surface: Surface?) {
        let pane = panes[workspace.focusedPaneUUID ?? ""] ?? orderedPanes(in: workspace).first
        let surface = pane.flatMap { surfaces[$0.selectedSurfaceUUID ?? ""] ?? orderedSurfaces(in: $0).first }
        return (pane, surface)
    }
}
