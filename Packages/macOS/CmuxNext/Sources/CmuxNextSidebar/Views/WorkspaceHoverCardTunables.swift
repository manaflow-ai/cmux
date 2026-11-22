public import CmuxNextDesign

/// When the workspace hover card draws the workspace's name above its tabs (Debug Settings
/// `sidebar.hoverCards.workspaceTitle`). Leo 2026-11-07: "if the inner tab is the exact same name as the workspace,
/// I feel like there's something that is kind of sort of redundant there ... do we even want to show the workspace
/// title at all, to be honest? Because, like, if you're hovering over it, you already see the workspace title."
public nonisolated enum WorkspaceHoverCardTitle: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The name, unless the workspace's one tab already reads it (the default): the tab row is the name.
    case unlessRepeated
    /// The name above the tabs on every card (before 2026-11-09).
    case always
    /// The name only with Show details open: the row under the pointer already shows it.
    case withDetails

    public var tunableTitle: String {
        switch self {
        case .unlessRepeated: "Unless its one tab repeats it"
        case .always: "Always"
        case .withDetails: "Only with details"
        }
    }

    /// The card shows the name: `tabTitles` are the workspace's tabs', `expanded` whether its details are open.
    public func showsTitle(_ title: String, tabTitles: [String], expanded: Bool) -> Bool {
        if expanded { return true }
        switch self {
        case .always: return true
        case .withDetails: return false
        case .unlessRepeated:
            guard tabTitles.count == 1, let only = tabTitles.first else { return true }
            return Self.normalized(only) != Self.normalized(title)
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// How the workspace hover card leaves once the pointer leaves its row (Debug Settings
/// `sidebar.hoverCards.workspaceLeave`). Leo 2026-11-07: "this is one of the more important hover previews because
/// it's how we navigate into the thing and navigate to different tabs. So I don't want it to disappear as quickly
/// as other ones would."
public nonisolated enum WorkspaceHoverCardLeaveStyle: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The card stays for the leave grace and a pointer heading into it keeps it (the default).
    case lingers
    /// The card fades the moment the pointer leaves its row and the card (Lawrence 2026-10-19, before 2026-11-09).
    case hidesAtOnce

    public var tunableTitle: String {
        switch self {
        case .lingers: "Lingers"
        case .hidesAtOnce: "Hides at once"
        }
    }
}

nonisolated extension SidebarTunables {
    public static let workspaceHoverCardTitle = Tunable<WorkspaceHoverCardTitle>.choice(
        "sidebar.hoverCards.workspaceTitle", .sidebar, "Workspace hover card name",
        help: "When the workspace hover card shows the workspace's name above its tabs: unless its one tab repeats it, always, or only with details.",
        default: .unlessRepeated, code: "SidebarTunables.workspaceHoverCardTitle")

    public static let workspaceHoverCardLeave = Tunable<WorkspaceHoverCardLeaveStyle>.choice(
        "sidebar.hoverCards.workspaceLeave", .sidebar, "Workspace hover card leave",
        help: "Whether the workspace hover card lingers for the leave grace after the pointer leaves its row, or hides at once.",
        default: .lingers, code: "SidebarTunables.workspaceHoverCardLeave")
}
