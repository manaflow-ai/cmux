public import CmuxNextDesign

/// How a workspace row shows what waits in it (Debug Settings `sidebar.rowBadge`). Leo and
/// Lawrence 2026-10-14: no count numbers on NEXT rows. The default follows T3 Code's thread list:
/// one small glyph says the most urgent state; the count reads in the hover card. Every style draws
/// in the trailing slot: nothing but the favicon or the user's icon draws in the leading slot
/// (Lawrence 2026-10-19). `stack` is Leo's alternative, one
/// glyph per pending item overlapping in the trailing slot; `trailing` keeps the count badge and
/// the trailing status glyph (the look before).
public nonisolated enum SidebarRowBadgeStyle: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// One glyph, the most urgent state, in the trailing slot (the case keeps its stored name).
    case corner
    /// Overlapping glyphs in the trailing slot, one per pending item, up to `SidebarRowBadgeStackCap`.
    case stack
    /// The count badge and the trailing status glyph.
    case trailing

    public var tunableTitle: String {
        switch self {
        case .corner: "One glyph (most urgent)"
        case .stack: "Glyph stack (one per item)"
        case .trailing: "Count and trailing glyph (before)"
        }
    }

    public static let tunable = Tunable<SidebarRowBadgeStyle>.choice(
        "sidebar.rowBadge", .sidebar, "Row badge",
        help: "How a workspace row shows unread items and agent states, at its end: one glyph for the most urgent state, a stack of glyphs, or the count with a trailing glyph.",
        default: .corner, code: "SidebarRowBadgeStyle.tunable")
}

/// A row's pending items, most urgent first: a failure, then a permission (or sign-in) request,
/// then a question, then work in progress, then each unread item (done). The one-glyph badge draws
/// the first; the stack draws up to `stackLimit` (`SidebarRowBadgeStackCap`) and leaves the rest to
/// the tooltip and hover card.
///
/// Unless `detailed` (`sidebar.detailedStatusIcons`, off by default), a row says one of two things
/// (Lawrence 2026-10-18: "it is working" or "it is blue and ready for me to look at it"): an error
/// (red), else needs you (orange), else Ready, the blue done dot (unread, done), else Working, the
/// one spinner (Lawrence msg 11983). `items` then holds at most one state; `unreadCount` and
/// `pending` keep what the tooltip lists. A program opts its row in to the finer icons with an
/// OSC 7501 report (`SidebarWorkspace.activityFromProgram`, Lawrence msg 1351).
nonisolated struct WorkspaceRowBadges: Equatable {
    var items: [StatusIndicatorState]
    /// Every pending item, detailed, for the tooltip.
    var pending: [StatusIndicatorState]
    var unreadCount: Int
    var stackLimit: Int

    init(unread: UnreadState, activity: StatusIndicatorState, stackLimit: Int = SidebarRowBadgeStackCap.five.limit,
         detailed: Bool = true) {
        self.stackLimit = stackLimit
        switch unread {
        case .none: unreadCount = 0
        case .dot: unreadCount = 1
        case let .count(n): unreadCount = max(0, n)
        }
        var items: [StatusIndicatorState] = activity == .idle || activity == .success ? [] : [activity]
        // Each unread item is a done dot; a finished workspace with nothing unread still shows one.
        items += Array(repeating: .success, count: unreadCount == 0 && activity == .success ? 1 : unreadCount)
        pending = items.sorted { Self.rank($0) < Self.rank($1) }
        self.items = detailed ? pending : Self.simple(pending).map { [$0] } ?? []
    }

    /// The one state a row shows without detailed icons, one color per meaning (Lawrence msg 11983:
    /// "blue, orange/yellow for needs attention, and red for errors"): an error (red), else needs
    /// you (`waiting`, one orange dot whatever it waits for), else Ready (`success`, the blue dot)
    /// for something unread or done, else the work in progress (its progress kept), else nothing.
    /// Never two dots (Leo 2026-10-21, on a blue dot beside "Needs you": "why ISN'T THIS JUST A
    /// YELLOW DOT!?").
    static func simple(_ items: [StatusIndicatorState]) -> StatusIndicatorState? {
        if items.contains(.error) { return .error }
        if items.contains(where: { if case .waiting = $0 { true } else { false } }) { return .waiting }
        let ready = items.contains { state in
            switch state {
            case .success: true
            case .idle, .busy, .paused, .working, .waiting, .error: false
            }
        }
        return ready ? .success : items.first { $0.isWorking || $0.isLoading }
    }

    var first: StatusIndicatorState? { items.first }
    var stacked: [StatusIndicatorState] { Array(items.prefix(stackLimit)) }
    /// The items the stack leaves to the hover card.
    var overflow: Int { max(0, items.count - stackLimit) }

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

/// Debug Settings `sidebar.rowBadgePreview` (`SidebarTunables.rowBadgePreview`): a section of
/// sample rows with 1 to 7 pending items, so the row badges can be seen without real sessions.
/// The rows are placeholders: nothing selects, opens or closes them.
extension SidebarSection {
    static let rowBadgePreviewMachine = MachineID("row-badge-preview")

    /// The preview rows' section: row N has N pending items, one state (unread, then each that
    /// needs the user, then work) and N - 1 unread.
    public static func rowBadgePreview() -> [SidebarSection] {
        let machine = rowBadgePreviewMachine
        let states: [StatusIndicatorState] = [.idle, .waiting(kind: .permission), .waiting(kind: .question), .working, .error,
                                              .waiting(kind: .permission), .error]
        let rows = states.enumerated().map { index, state in
            let count = index + 1
            let unread = state == .idle ? count : count - 1
            var row = SidebarWorkspace(
                id: WorkspaceID("row-badge-preview-\(count)"), machineID: machine, title: count == 1 ? "1 item" : "\(count) items",
                kind: .terminal, unread: unread > 0 ? .count(unread) : .none, activity: state, rowState: .placeholder, isClosable: false)
            // Agent work shows only on a row whose agent is working (`WorkspaceRowContent.activity`).
            row.agentWorking = state == .working
            return SidebarNode.workspace(row)
        }
        return [SidebarSection(kind: .machine(SidebarMachine(id: machine, name: "Badge preview", kind: .server)), nodes: rows)]
    }
}
