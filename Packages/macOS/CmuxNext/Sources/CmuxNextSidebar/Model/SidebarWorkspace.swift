public import CmuxNextDesign
public import CmuxNextIcons
import Foundation

/// Unread state for the badge.
public nonisolated enum UnreadState: Hashable, Sendable {
    case none
    case dot
    case count(Int)

    public var isUnread: Bool {
        switch self {
        case .none: false
        case .dot: true
        case let .count(n): n > 0
        }
    }
}

/// The strongest tab type represented by a workspace row.
public nonisolated enum SidebarWorkspaceKind: String, Codable, Hashable, Sendable {
    /// A workspace with an adopted Claude or Codex harness tab.
    case harness
    /// A workspace whose tabs are terminals or remote terminals.
    case terminal
    /// A workspace containing a browser tab and no harness tab.
    case browser

    /// The leading symbol shown when the workspace has no custom icon.
    public var symbol: String {
        switch self {
        case .harness: "bubble.left.and.text.bubble.right"
        case .terminal: "terminal"
        case .browser: "globe"
        }
    }

    /// The matching built-in icon-pack glyph for rows without a custom icon.
    public var iconName: IconName {
        switch self {
        case .harness: .agentChat
        case .terminal: .terminal
        case .browser: .browser
        }
    }
}

/// One workspace row.
public nonisolated struct SidebarWorkspace: Identifiable, Hashable, Sendable {
    public var id: WorkspaceID
    /// The machine whose daemon owns this workspace. Workspaces never move
    /// between machines; drops across machine sections are refused.
    public var machineID: MachineID
    public var title: String
    /// Passive detail (cwd, git branch). Shown in the tooltip and
    /// accessibility label, never as a second line: it rarely changes and
    /// repeats on every row.
    public var subtitle: String?
    /// Live status (agent status line, hook `set_status`). The only text
    /// that earns the row a second line.
    public var status: String?
    /// Set only when the user chose an icon or color. When nil, the row uses
    /// ``SidebarWorkspaceKind.symbol`` so every row keeps a type glyph.
    public var icon: WorkspaceIcon?
    /// The leading type represented by the workspace's tabs.
    public var kind: SidebarWorkspaceKind
    public var unread: UnreadState
    /// The row's status indicator: the merged status of the workspace's
    /// tabs and its own status entries (`StatusStack`), drawn by the
    /// shared `StatusIndicatorView`.
    public var activity: StatusIndicatorState
    /// The winning report's style hint (`cmux status set --style`).
    public var activityStyle: StatusIndicatorStyle?
    /// The brand id (CmuxAgentBrands) of an agent working or waiting in one of the
    /// workspace's tabs; the row draws its mark per `SidebarAgentMarkVariant`.
    public var agentBrand: String?
    /// Determinate or indeterminate bar under the row: the workspace's
    /// reported progress, else a terminal's OSC 9;4 progress.
    public var progress: SidebarProgress?
    /// Tabs in pane order, shown only when the sidebar tab setting is enabled.
    public var tabs: [SidebarTab]
    /// Live daemon data, a saved row drawn before the daemon answered, or a
    /// placeholder (`SidebarRowState`).
    public var rowState: SidebarRowState

    public init(
        id: WorkspaceID,
        machineID: MachineID = .local,
        title: String,
        subtitle: String? = nil,
        status: String? = nil,
        icon: WorkspaceIcon? = nil,
        kind: SidebarWorkspaceKind = .terminal,
        unread: UnreadState = .none,
        activity: StatusIndicatorState = .idle,
        activityStyle: StatusIndicatorStyle? = nil,
        agentBrand: String? = nil,
        progress: SidebarProgress? = nil,
        tabs: [SidebarTab] = [],
        rowState: SidebarRowState = .live
    ) {
        self.id = id
        self.machineID = machineID
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.icon = icon
        self.kind = kind
        self.unread = unread
        self.activity = activity
        self.activityStyle = activityStyle
        self.agentBrand = agentBrand
        self.progress = progress
        self.tabs = tabs
        self.rowState = rowState
    }
}

nonisolated extension SidebarWorkspace {
    /// The second line, when the row carries live information.
    public var liveDetail: String? {
        guard let status, !status.isEmpty else { return nil }
        return status
    }
}
