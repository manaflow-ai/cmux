public import CmuxNextDesign
import AppKit

/// How the sidebar surfaces a workspace with a notification (Debug Settings `sidebar.notificationEmphasis`).
/// Aziz 2026-11-05: the trailing 8 pt dot "doesn't capture my attention enough"; a first round of row
/// decorations (an edge bar, a count pill, a halo) was "too timid". These three change the sidebar's
/// structure instead, each a different idea of where the person's eye should go:
/// - `inbox`: the workspaces with something for you gather in a shelf pinned at the top of the sidebar,
///   above everything, whatever their place in the list, scrolled or folded away.
/// - `arrivalCard`: a notification arrives as an event: a card rises at the bottom of the sidebar naming
///   the workspace and why, and its row flashes; it stays until you open it, read it or dismiss it.
/// - `loudRows`: a row with a notification paints solid in its color with white text, and when such rows
///   are scrolled out of view a beacon at the list's top or bottom edge says how many and takes you there.
/// `standard` keeps the dot alone (the shipped look) until the person picks one.
public nonisolated enum SidebarNotificationEmphasis: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The trailing dot only (the look before).
    case standard
    /// A Needs You shelf pinned at the top of the sidebar.
    case inbox
    /// A card at the bottom of the sidebar for each new notification, and its row flashes.
    case arrivalCard
    /// Solid colored rows, and edge beacons for the ones scrolled out of view.
    case loudRows

    public var tunableTitle: String {
        switch self {
        case .standard: "Dot only (current)"
        case .inbox: "Inbox shelf at the top"
        case .arrivalCard: "Arrival card and flash"
        case .loudRows: "Loud rows and edge beacons"
        }
    }

    public static let tunable = Tunable<SidebarNotificationEmphasis>.choice(
        "sidebar.notificationEmphasis", .sidebar, "Notification emphasis",
        help: "How the sidebar surfaces a workspace with a notification: the trailing dot only, a Needs You shelf pinned at the top, an arrival card with a row flash, or solid colored rows with edge beacons for the ones out of view.",
        default: .standard, code: "SidebarNotificationEmphasis.tunable")
}

/// What a workspace has for the person: its kind and its unread count. nil: nothing waits.
nonisolated struct WorkspaceRowAttention: Equatable {
    enum Kind: Int, Comparable {
        // Most urgent first.
        case failed, needsYou, unread
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    var kind: Kind
    /// Unread items; 0 for a workspace that only needs you or failed.
    var count: Int
    /// What a hook said it waits for, when it said.
    var blocked: StatusBlockedKind?

    /// What the badge leads with (`leading`, its first glyph; nil reads the one state it says without
    /// detailed icons, `WorkspaceRowBadges.simple`), when it is something for the person. A badge that
    /// leads with work in progress has no attention, so the spinner stays as it is.
    init?(_ badges: WorkspaceRowBadges, leading: StatusIndicatorState? = nil) {
        let state = leading ?? WorkspaceRowBadges.simple(badges.pending)
        switch state {
        case .error?: kind = .failed
        case let .waiting(kind: waits)?: kind = .needsYou; blocked = waits
        case .success? where badges.unreadCount > 0: kind = .unread
        default: return nil
        }
        count = badges.unreadCount
    }

    /// A workspace's attention from its own unread mark and activity, as its row's badge says it.
    init?(_ ws: SidebarWorkspace) {
        guard ws.rowState != .placeholder else { return nil }
        self.init(WorkspaceRowBadges(unread: ws.unread, activity: ws.activity, detailed: false))
    }

    /// The badge's own color, so every surface and the dot agree (Lawrence msg 11983).
    @MainActor var color: NSColor {
        switch kind {
        case .unread: Palette.statusUnread
        case .needsYou: Palette.statusAttention
        case .failed: Palette.statusError
        }
    }

    /// The count a pill says: the unread count, capped, or "!" for one that needs you or failed with nothing unread.
    var pillText: String {
        count > 0 ? (count > 99 ? "99+" : String(count)) : "!"
    }
}

/// One workspace with something for the person, in the sidebar's drawn order.
nonisolated struct SidebarAttentionItem: Equatable {
    var id: WorkspaceID
    var title: String
    var attention: WorkspaceRowAttention

    /// Every workspace with a notification, in sidebar order (loose rows and each group's members in their
    /// place, folded groups too); a workspace listed twice (a pin) counts once.
    static func all(in sections: [SidebarSection]) -> [SidebarAttentionItem] {
        var seen: Set<WorkspaceID> = [], items: [SidebarAttentionItem] = []
        func visit(_ nodes: [SidebarNode]) {
            for node in nodes {
                switch node {
                case let .workspace(ws):
                    guard seen.insert(ws.id).inserted, !ws.isArchived, let attention = WorkspaceRowAttention(ws) else { continue }
                    items.append(SidebarAttentionItem(id: ws.id, title: ws.title, attention: attention))
                case let .group(group):
                    visit(group.members)
                case .item:
                    break
                }
            }
        }
        for section in sections { visit(section.nodes) }
        return items
    }
}

/// The arrival card's queue (`arrivalCard`): workspaces whose notification arrived since the sidebar first
/// drew, newest first; one leaves when it no longer has a notification (opened, read) or the card is dismissed.
/// What was already waiting at launch is not an arrival, so a relaunch never floods the card.
nonisolated struct SidebarArrivals: Equatable {
    /// What had a notification at the last update; nil until the first.
    private(set) var known: [WorkspaceID: WorkspaceRowAttention.Kind]?
    private(set) var queue: [WorkspaceID] = []

    /// Takes the current items; returns the ids that just arrived (a new notification, or one that got more urgent).
    mutating func update(_ items: [SidebarAttentionItem]) -> [WorkspaceID] {
        let now = Dictionary(items.map { ($0.id, $0.attention.kind) }, uniquingKeysWith: { a, _ in a })
        defer { known = now }
        guard let known else { return [] }
        let arrived = items.filter { item in known[item.id].map { item.attention.kind < $0 } ?? true }.map(\.id)
        queue = arrived + queue.filter { now[$0] != nil && !arrived.contains($0) }
        return arrived
    }

    mutating func dismiss() { queue = [] }
}
