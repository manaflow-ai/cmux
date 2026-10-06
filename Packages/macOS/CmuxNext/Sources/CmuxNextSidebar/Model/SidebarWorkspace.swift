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

/// What a workspace row shows: the kind of its selected tab.
public nonisolated enum SidebarWorkspaceKind: String, Codable, Hashable, Sendable {
    /// An agent: an agent chat, a Home conversation or an agent terminal.
    case harness
    /// A terminal or remote terminal.
    case terminal
    /// A browser page.
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
    /// Passive detail such as the cwd or git branch. It is used as the row's
    /// secondary line when no live status is available.
    public var subtitle: String?
    /// Live status from the agent or hook `set_status`. It takes precedence
    /// over ``subtitle`` in the row's secondary line.
    public var status: String?
    /// Set only when the user chose an icon or color. When nil, the row draws
    /// ``kindBrand``'s mark, else ``SidebarWorkspaceKind.iconName``, so every
    /// row keeps a type glyph.
    public var icon: WorkspaceIcon?
    /// The kind of the workspace's selected tab.
    public var kind: SidebarWorkspaceKind
    /// The brand id (CmuxAgentBrands) of the agent in the selected tab, whose
    /// mark is the row's type glyph; nil for other tabs and unknown agents.
    public var kindBrand: String?
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
        kindBrand: String? = nil,
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
        self.kindBrand = kindBrand
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

    /// The most useful detail to show below the workspace title.
    public var rowDetail: String? {
        liveDetail ?? subtitle.flatMap { $0.isEmpty ? nil : $0 }
    }
}
