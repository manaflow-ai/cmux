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

    /// A workspace's attention from its own unread mark and activity, as its row's badge says it. A placeholder
    /// that draws only its loading bar (no title yet) has none, as its row shows no badge (`isShowingPlaceholder`).
    init?(_ ws: SidebarWorkspace) {
        guard !(ws.rowState == .placeholder && ws.title.isEmpty) else { return nil }
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
        scan(sections).items
    }

    /// `all(in:)`, and the workspaces whose rows report what they have now (`reports(_:)`), for `SidebarArrivals`.
    static func scan(_ sections: [SidebarSection]) -> (items: [SidebarAttentionItem], reporting: Set<WorkspaceID>) {
        var seen: Set<WorkspaceID> = [], items: [SidebarAttentionItem] = [], reporting: Set<WorkspaceID> = []
        func add(_ ws: SidebarWorkspace) {
            guard seen.insert(ws.id).inserted, !ws.isArchived else { return }
            let attention = WorkspaceRowAttention(ws)
            if reports(ws, attention) { reporting.insert(ws.id) }
            guard let attention else { return }
            items.append(SidebarAttentionItem(id: ws.id, title: ws.title, attention: attention))
        }
        for section in sections {
            for node in section.nodes {
                switch node {
                case let .workspace(ws):
                    add(ws)
                case let .group(group):
                    for case let .workspace(ws) in group.members { add(ws) }
                case .item:
                    break
                }
            }
        }
        return (items, reporting)
    }

    /// Whether a row says what its workspace has now: a live row does; a saved (stale) row or a connecting
    /// machine's placeholder carries no unread or activity (`SidebarSnapshot` never saves them), so its "nothing"
    /// is not news. A placeholder that does carry a notification (the Debug badge preview rows) reports it.
    private static func reports(_ ws: SidebarWorkspace, _ attention: WorkspaceRowAttention?) -> Bool {
        ws.rowState == .live || (ws.rowState == .placeholder && attention != nil)
    }
}

/// The arrival card's queue (`arrivalCard`): workspaces whose notification arrived since the sidebar first
/// drew, newest first; one leaves when it no longer has a notification (opened, read) or the card is dismissed.
/// A workspace's first report is its baseline, not an arrival: what waits at launch, or when a saved row or a
/// connecting machine's row turns live, never floods the card.
nonisolated struct SidebarArrivals: Equatable {
    /// What each workspace had at its last report (nil kind: nothing). A workspace that left the list keeps
    /// "nothing", so a notification it brings back arrives.
    private(set) var known: [WorkspaceID: Seen] = [:]
    private(set) var queue: [WorkspaceID] = []
    private var started = false

    struct Seen: Equatable {
        var kind: WorkspaceRowAttention.Kind?
        var count: Int
    }

    /// Takes the current items and the workspaces whose rows report (`SidebarAttentionItem.scan`); returns the
    /// ids that just arrived: a notification where there was none, a more urgent one, or more unread of the same kind.
    mutating func update(_ items: [SidebarAttentionItem], reporting: Set<WorkspaceID>) -> [WorkspaceID] {
        let byID = Dictionary(items.map { ($0.id, $0.attention) }, uniquingKeysWith: { a, _ in a })
        var arrived: [WorkspaceID] = []
        for id in Set(known.keys).subtracting(reporting) where known[id]?.kind != nil && byID[id] == nil {
            known[id] = Seen(kind: nil, count: 0) // gone or read while not reporting: nothing now
        }
        for id in reporting {
            let now = Seen(kind: byID[id]?.kind, count: byID[id]?.count ?? 0)
            defer { known[id] = now }
            guard started, let was = known[id], let kind = now.kind else { continue }
            if was.kind.map({ kind < $0 || (kind == $0 && now.count > was.count) }) ?? true { arrived.append(id) }
        }
        started = true
        // Sidebar order among those that arrived together.
        arrived = items.map(\.id).filter(arrived.contains)
        queue = arrived + queue.filter { byID[$0] != nil && !arrived.contains($0) }
        return arrived
    }

    mutating func dismiss() { queue = [] }
}
