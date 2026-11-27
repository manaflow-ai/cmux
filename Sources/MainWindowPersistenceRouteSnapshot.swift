import AppKit

/// A bounded session-persistence input backed by either live state or a frozen value.
@MainActor
enum MainWindowPersistenceRouteSnapshot {
    case live(MainWindowRouteSnapshot)
    case frozen(windowId: UUID, snapshot: SessionWindowSnapshot)

    var windowId: UUID {
        switch self {
        case .live(let route):
            route.windowId
        case .frozen(let windowId, _):
            windowId
        }
    }

    var window: NSWindow? {
        guard case .live(let route) = self else { return nil }
        return route.window
    }

    var workspaceCount: Int {
        switch self {
        case .live(let route):
            route.tabManager.tabs.count
        case .frozen(_, let snapshot):
            snapshot.tabManager.workspaces.count
        }
    }

    var selectedWorkspaceId: UUID? {
        switch self {
        case .live(let route):
            return route.tabManager.selectedTabId
        case .frozen(_, let snapshot):
            guard let index = snapshot.tabManager.selectedWorkspaceIndex,
                  snapshot.tabManager.workspaces.indices.contains(index) else {
                return nil
            }
            return snapshot.tabManager.workspaces[index].workspaceId
        }
    }

    var hasWindowDock: Bool {
        switch self {
        case .live(let route):
            route.dock != nil
        case .frozen(_, let snapshot):
            snapshot.dock != nil
        }
    }

    /// Remote-tmux-only live windows require their active SSH control graph
    /// and intentionally do not participate in persisted session topology.
    var isEligibleForSessionPersistence: Bool {
        switch self {
        case .live(let route):
            let workspaces = route.tabManager.tabs
            let omitsRemoteMirrorOnlyWindow = route.dock == nil
                && !workspaces.isEmpty
                && workspaces.allSatisfy(\.isRemoteTmuxMirror)
            return !omitsRemoteMirrorOnlyWindow
        case .frozen:
            return true
        }
    }
}
