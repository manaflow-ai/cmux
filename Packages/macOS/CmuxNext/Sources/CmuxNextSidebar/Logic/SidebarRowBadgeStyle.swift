public import CmuxNextDesign

/// How a workspace row shows what waits in it (Debug Settings `sidebar.rowBadge`). Leo and
/// Lawrence 2026-10-14: no count numbers on NEXT rows. The default follows T3 Code's thread list:
/// the row leads with its harness logo or kind icon, and one small badge on that icon's corner says
/// the most urgent state; the count reads in the hover card. `stack` is Leo's alternative, one
/// glyph per pending item overlapping in the trailing slot; `trailing` keeps the count badge and
/// the trailing status glyph (the look before).
public nonisolated enum SidebarRowBadgeStyle: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// One badge on the leading icon's bottom-right corner.
    case corner
    /// Up to three overlapping glyphs in the trailing slot, one per pending item.
    case stack
    /// The count badge and the trailing status glyph.
    case trailing

    public var tunableTitle: String {
        switch self {
        case .corner: "Corner badge on the icon"
        case .stack: "Glyph stack (one per item)"
        case .trailing: "Count and trailing glyph (before)"
        }
    }

    public static let tunable = Tunable<SidebarRowBadgeStyle>.choice(
        "sidebar.rowBadge", .sidebar, "Row badge",
        help: "How a workspace row shows unread items and agent states: a badge on the leading icon's corner, a stack of glyphs, or the count with a trailing glyph.",
        default: .corner, code: "SidebarRowBadgeStyle.tunable")
}

/// A row's pending items, most urgent first: a failure, then a permission (or sign-in) request,
/// then a question, then work in progress, then each unread item (done). The corner badge draws
/// the first; the stack draws up to `stackLimit` and leaves the rest to the hover card.
nonisolated struct WorkspaceRowBadges: Equatable {
    static let stackLimit = 3

    var items: [StatusIndicatorState]
    var unreadCount: Int

    init(unread: UnreadState, activity: StatusIndicatorState) {
        switch unread {
        case .none: unreadCount = 0
        case .dot: unreadCount = 1
        case let .count(n): unreadCount = max(0, n)
        }
        var items: [StatusIndicatorState] = activity == .idle || activity == .success ? [] : [activity]
        // Each unread item is a done dot; a finished workspace with nothing unread still shows one.
        items += Array(repeating: .success, count: unreadCount == 0 && activity == .success ? 1 : unreadCount)
        self.items = items.sorted { Self.rank($0) < Self.rank($1) }
    }

    var first: StatusIndicatorState? { items.first }
    var stacked: [StatusIndicatorState] { Array(items.prefix(Self.stackLimit)) }
    /// The items the stack leaves to the hover card.
    var overflow: Int { max(0, items.count - Self.stackLimit) }

    static func rank(_ state: StatusIndicatorState) -> Int {
        switch state {
        case .error: 0
        case .waiting(kind: .permission?), .waiting(kind: .auth?): 1
        case .waiting: 2
        case .working, .busy, .paused: 3
        case .success: 4
        case .idle: 5
        }
    }
}

/// How many glyphs the stack shows before the rest go to the tooltip and hover card (Debug
/// Settings `sidebar.rowBadgeStack`; Leo 2026-10-14: five, adjustable to 3 or 7).
public nonisolated enum SidebarRowBadgeStackCap: String, Sendable, CaseIterable, Hashable, TunableChoice {
    case three, five, seven

    public var limit: Int {
        switch self {
        case .three: 3
        case .five: 5
        case .seven: 7
        }
    }

    public var tunableTitle: String { "\(limit) glyphs" }

    public static let tunable = Tunable<SidebarRowBadgeStackCap>.choice(
        "sidebar.rowBadgeStack", .sidebar, "Row badge stack size",
        help: "How many glyphs the stack row badge shows before the rest read in the tooltip and hover card.",
        default: .five, code: "SidebarRowBadgeStackCap.tunable")
}

/// Debug Settings `sidebar.rowBadgePreview`: a section of sample rows with 1 to 7 pending items,
/// so the row badges can be seen without real sessions. The rows are placeholders: nothing
/// selects, opens or closes them.
public nonisolated enum SidebarRowBadgePreview {
    public static let tunable = Tunable<Bool>.toggle(
        "sidebar.rowBadgePreview", .sidebar, "Row badge preview rows",
        help: "Adds sample rows with 1 to 7 pending items to the sidebar, to compare the row badges without real sessions.",
        default: false, code: "SidebarRowBadgePreview.tunable")

    /// The preview rows' section.
    public static func sections() -> [SidebarSection] { [] }
}
