public import CmuxNextSettings

/// The window / workspace / pane / tab tree as the control socket reports
/// it, mapped by the App from the daemon mirror and window state. Ids are
/// the durable string ids the CLI uses; handles are the daemon's
/// session-scoped handles, for commands.
public struct ControlTopology: Sendable, Hashable {
    public var isLoaded = false
    /// `connecting`, `connected`, `disconnected`, or `failed`.
    public var daemonState = "connecting"
    public var windows: [ControlWindowInfo] = []
    public var workspaceGroups: [ControlWorkspaceGroupInfo] = []
    public var workspaces: [ControlWorkspaceInfo] = []
    public var focus = ControlFocus()

    public init() {}

    public func workspace(id: String) -> ControlWorkspaceInfo? { workspaces.first { $0.id == id || $0.handle == id } }

    /// The pane with durable id or handle `id`, and its workspace.
    public func pane(id: String) -> (pane: ControlPaneInfo, workspace: ControlWorkspaceInfo)? {
        for workspace in workspaces {
            for screen in workspace.screens {
                if let pane = screen.panes.first(where: { $0.id == id || $0.handle == id }) { return (pane, workspace) }
            }
        }
        return nil
    }

    /// The tab with durable id or surface handle `id`, its pane, and workspace.
    public func tab(id: String) -> (tab: ControlTabInfo, pane: ControlPaneInfo, workspace: ControlWorkspaceInfo)? {
        for workspace in workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    if let tab = pane.tabs.first(where: { $0.id == id || $0.surface == id }) { return (tab, pane, workspace) }
                }
            }
        }
        return nil
    }

    public var tabCount: Int { workspaces.reduce(0) { $0 + $1.screens.reduce(0) { $0 + $1.panes.reduce(0) { $0 + $1.tabs.count } } } }
}

/// Which window, workspace, pane, and tab have focus (app-local state).
public struct ControlFocus: Sendable, Hashable {
    public var windowID: String?
    public var workspaceID: String?
    public var paneID: String?
    public var tabID: String?

    public init(windowID: String? = nil, workspaceID: String? = nil, paneID: String? = nil, tabID: String? = nil) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.tabID = tabID
    }
}

public struct ControlWindowInfo: Sendable, Hashable {
    public var id: String
    public var workspaceID: String?
    public var isKey: Bool
    public var isVisible: Bool
    public var focusedPaneID: String?

    public init(id: String, workspaceID: String?, isKey: Bool, isVisible: Bool, focusedPaneID: String?) {
        self.id = id
        self.workspaceID = workspaceID
        self.isKey = isKey
        self.isVisible = isVisible
        self.focusedPaneID = focusedPaneID
    }
}
