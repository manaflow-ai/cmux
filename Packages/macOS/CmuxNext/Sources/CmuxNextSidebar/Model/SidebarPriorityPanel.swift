public import Foundation

/// One chat in the sidebar's Priority view: every agent chat on every machine, the ones that need
/// the person first. The App ranks them (`AgentPriorityRanking`); the sidebar only draws them in
/// the order it gets and sends the person's choices back (`SidebarPriorityAction`).
public nonisolated struct SidebarPriorityEntry: Hashable, Sendable, Identifiable {
    /// What the chip at the row's right says.
    public enum State: Hashable, Sendable {
        /// A permission prompt or a question waits for the person.
        case needsYou
        /// The last turn answered and nobody has seen it yet.
        case done
        /// The last turn failed.
        case failed
        /// The agent process or its machine is gone.
        case lost
        /// Red CI: a pull request of the chat's (its folder's branch's, or one it opened) has
        /// failing checks.
        case ciFailing
        /// A turn runs, since the date when known.
        case working(since: Date?)
        case idle
    }

    /// The chat's session id.
    public let id: String
    public var title: String
    /// The project (the session folder's name), else nil.
    public var project: String?
    /// The machine it runs on, nil on this Mac; its tag takes the machine's color.
    public var machine: String?
    /// The latest line from the chat, up to two lines in the row.
    public var preview: String?
    public var state: State
    /// The blue dot: the person has not seen the chat's latest result.
    public var unread: Bool
    /// Pinned to the Priority view: first in its tier, and kept while idle.
    public var pinned: Bool

    public init(id: String, title: String, project: String? = nil, machine: String? = nil, preview: String? = nil,
                state: State, unread: Bool = false, pinned: Bool = false) {
        self.id = id
        self.title = title
        self.project = project
        self.machine = machine
        self.preview = preview
        self.state = state
        self.unread = unread
        self.pinned = pinned
    }

    /// Needs the person: waiting on them, finished unseen, failed, lost or Red CI.
    public var needsAttention: Bool {
        switch state {
        case .needsYou, .done, .failed, .lost, .ciFailing: true
        case .working, .idle: false
        }
    }

    /// Mark as Read applies: a result or a failure. A question is answered, not read, and red
    /// checks stay until they pass, so a Red CI row has nothing to mark read.
    public var canMarkRead: Bool { needsAttention && state != .needsYou && state != .ciFailing }
}

/// What the sidebar's Priority view shows while it is installed (`sidebar.priorityView.enabled`):
/// the titlebar bell, and while the bell is on, the rows in rank order.
public nonisolated struct SidebarPriorityPanel: Hashable, Sendable {
    public var entries: [SidebarPriorityEntry]
    /// The bell is on: the view shows at the top of the sidebar. Off, only the bell shows.
    public var shown: Bool
    /// Folded to its header, which then shows the attention count.
    public var collapsed: Bool
    /// The toggle action's shortcut as the person sees it ("⌥⌘K"), for the bell's tooltip.
    public var shortcut: String?

    public init(entries: [SidebarPriorityEntry], shown: Bool = true, collapsed: Bool = false, shortcut: String? = nil) {
        self.entries = entries
        self.shown = shown
        self.collapsed = collapsed
        self.shortcut = shortcut
    }

    /// The rows that need the person (the folded header's count and the bell's dot).
    public var attentionCount: Int { entries.count(where: \.needsAttention) }
    /// The bell carries a dot while something needs the person and the rows are out of sight.
    public var bellDot: Bool { attentionCount > 0 && (!shown || collapsed) }
}

/// A choice the person made in the Priority view. The App carries it out.
public nonisolated enum SidebarPriorityAction: Hashable, Sendable {
    /// Open or focus the chat.
    case open(String)
    case markRead(String)
    case togglePin(String)
    /// Hide the row until its state changes or an hour passes.
    case snooze(String)
    case archive(String)
    case setCollapsed(Bool)
    /// The person dragged the chat; the view now shows `order` (top first). It keeps that place.
    case place(String, order: [String])
    /// The titlebar bell: show or hide the view.
    case toggleShown
}
