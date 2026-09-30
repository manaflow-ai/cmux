import CmuxNextDaemon
import Foundation

/// One immutable view of everything the old CLI can name: the daemon tree
/// (fetched fresh per request, so a read that follows a write sees it) joined
/// with the App's frontend snapshot, with old-app UUIDs, refs, and indexes.
/// Built off the main actor; never mutated.
struct CompatWorld: Sendable {
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
    func workspaces(in window: Window?) -> [Workspace] {
        guard let window, !window.workspaceUUIDs.isEmpty else { return workspaces }
        let members = Set(window.workspaceUUIDs)
        return workspaces.filter { members.contains($0.uuid) }
    }

    /// The workspace a window shows, else the first one.
    func currentWorkspace(window: Window?) -> Workspace? {
        workspace(window?.workspaceUUID) ?? workspaces.first
    }

    /// Focused pane and surface of a workspace.
    func focus(in workspace: Workspace) -> (pane: Pane?, surface: Surface?) {
        let pane = panes[workspace.focusedPaneUUID ?? ""] ?? orderedPanes(in: workspace).first
        let surface = pane.flatMap { surfaces[$0.selectedSurfaceUUID ?? ""] ?? orderedSurfaces(in: $0).first }
        return (pane, surface)
    }
}
