public import CmuxNextDesign

/// What a sub-session is doing, as its nested sidebar row draws it (acpmux's `indicator`).
public nonisolated enum SidebarSubsessionState: Hashable, Sendable {
    case idle
    case working
    case needsInput
    case failed
    /// Its last turn finished while no pane showed it (acpmux `unread`).
    case done

    /// Work runs or waits on the person: its parent's list opens by default.
    public var isActive: Bool { self == .working || self == .needsInput }

    /// The shared status indicator's state for it.
    public var indicator: StatusIndicatorState {
        switch self {
        case .idle: .idle
        case .working: .working
        case .needsInput: .waiting
        case .failed: .error
        case .done: .success
        }
    }
}

/// A session an agent chat's agent started (an acpmux sub-session, at any depth), listed nested
/// under the chat's tab in the sidebar. Clicking it opens its chat beside the parent's tab.
public nonisolated struct SidebarSubsession: Identifiable, Hashable, Sendable {
    /// The acpmux session id.
    public var id: String
    /// Its short name among its parent's sub-sessions, else its chat title.
    public var title: String
    public var state: SidebarSubsessionState
    public var isUnread: Bool
    /// Prompts waiting behind its running turn.
    public var queued: Int
    /// 1 for a child of the tab's chat, 2 for a grandchild, and so on.
    public var depth: Int

    public init(id: String, title: String, state: SidebarSubsessionState = .idle, isUnread: Bool = false, queued: Int = 0,
                depth: Int = 1) {
        self.id = id
        self.title = title
        self.state = state
        self.isUnread = isUnread
        self.queued = queued
        self.depth = depth
    }
}

/// The tab id a nested sub-session row is listed under (`SidebarRowKey.tab`): its parent tab's
/// header (the disclosure with the count) or one sub-session. Never the id of a real tab, so the
/// tab paths (select, drag, menus) can tell a nested row apart.
public nonisolated struct SidebarSubsessionRowID: Hashable, Sendable {
    /// The agent chat tab the row nests under.
    public var parentTab: TabID
    /// The sub-session; nil for the header.
    public var session: String?

    private static let prefix = "subsessions\u{1F}"
    private static let separator: Character = "\u{1F}"

    public init(parentTab: TabID, session: String? = nil) {
        self.parentTab = parentTab
        self.session = session
    }

    /// The nested row `tab` names; nil for a real tab.
    public init?(_ tab: TabID) {
        guard tab.rawValue.hasPrefix(Self.prefix) else { return nil }
        let parts = tab.rawValue.dropFirst(Self.prefix.count).split(separator: Self.separator, maxSplits: 1,
                                                                    omittingEmptySubsequences: false)
        guard let parent = parts.first, !parent.isEmpty else { return nil }
        parentTab = TabID(String(parent))
        session = parts.count > 1 ? String(parts[1]) : nil
    }

    /// The row's id in the list.
    public var tabID: TabID {
        TabID(Self.prefix + parentTab.rawValue + (session.map { String(Self.separator) + $0 } ?? ""))
    }
}
