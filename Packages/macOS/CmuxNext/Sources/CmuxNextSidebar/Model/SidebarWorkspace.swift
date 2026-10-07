public import CmuxNextDesign
public import CmuxNextIcons
public import Foundation

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
    /// Row facts. Which ones a row shows is `sidebar.workspaceRow.*`
    /// (`WorkspaceRowContent`); none shows by default.
    /// The folder of the first tab that reports one, `~`-abbreviated.
    public var directory: String?
    /// That tab's git branch.
    public var branch: String?
    /// The front terminal's program, as the shell or program titles it.
    public var process: String?
    /// The status line agents and hooks report (`cmux workspace status set`),
    /// without the entries other elements show (ports, pr).
    public var status: String?
    /// Listening ports a hook reported (status entry `ports`).
    public var ports: String?
    /// A pull request / CI badge a hook reported (status entry `pr`).
    public var pullRequest: String?
    /// When an agent or a notification last changed the workspace.
    public var lastActivity: Date?
    /// What the workspace's tabs are, for per-kind row settings.
    public var rowKind: WorkspaceRowKind
    /// An agent turn runs in one of the workspace's tabs (daemon agent
    /// state): the row's working indicator.
    public var agentWorking: Bool
    /// Set only when the user chose an icon or color. When nil, the row
    /// draws no icon (WORKSPACE-ROWS-NO-DEFAULT-ICON).
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
    /// The user muted the workspace's notifications
    /// (`notifications.mutedWorkspaces`); the row draws a quiet mark.
    public var muted: Bool
    /// False for a workspace no close path closes (the store's home
    /// workspace, `home_not_closable`): the row offers no close button.
    public var isClosable: Bool
    /// The front tab's working directory, abbreviated (`~/src/app`): the
    /// bucket Group by Folder puts the row in. Nil when no tab reports one.
    public var folder: String?

    public init(
        id: WorkspaceID,
        machineID: MachineID = .local,
        title: String,
        directory: String? = nil,
        branch: String? = nil,
        process: String? = nil,
        status: String? = nil,
        ports: String? = nil,
        pullRequest: String? = nil,
        lastActivity: Date? = nil,
        rowKind: WorkspaceRowKind? = nil,
        agentWorking: Bool = false,
        icon: WorkspaceIcon? = nil,
        kind: SidebarWorkspaceKind = .terminal,
        kindBrand: String? = nil,
        unread: UnreadState = .none,
        activity: StatusIndicatorState = .idle,
        activityStyle: StatusIndicatorStyle? = nil,
        agentBrand: String? = nil,
        progress: SidebarProgress? = nil,
        tabs: [SidebarTab] = [],
        rowState: SidebarRowState = .live,
        muted: Bool = false,
        isClosable: Bool = true,
        folder: String? = nil
    ) {
        self.id = id
        self.machineID = machineID
        self.title = title
        self.directory = directory
        self.branch = branch
        self.process = process
        self.status = status
        self.ports = ports
        self.pullRequest = pullRequest
        self.lastActivity = lastActivity
        self.rowKind = rowKind ?? kind.rowKind
        self.agentWorking = agentWorking
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
        self.muted = muted
        self.isClosable = isClosable
        self.folder = folder
    }
}

nonisolated extension SidebarWorkspaceKind {
    /// The row kind of a workspace whose tabs are all of this kind.
    public var rowKind: WorkspaceRowKind {
        switch self {
        case .harness: .agent
        case .terminal: .terminal
        case .browser: .browser
        }
    }
}

nonisolated extension SidebarWorkspace {
    /// The folder and branch, for the hover card and the filter (not a row
    /// element: the row shows each through its own setting).
    public var folderLine: String? {
        let parts = [directory, branch].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: WorkspaceRowContent.separator)
    }
}
