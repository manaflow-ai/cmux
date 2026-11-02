import Foundation

/// How the workspace hover card lays out its tab list (Lawrence msg 19245: "alignment here looks bad ...
/// not showing enough details per each"). `standard` is the shipped card; the other values exist for the
/// variants gallery (`AAWorkspaceHoverCardVariantsGalleryTests`). Every style keeps one grid: one icon
/// column and one text column for the header, the tab rows, "Show N more" and "Show details".
struct WorkspaceTabHoverCardStyle: Hashable, Sendable {
    /// A fact a tab row's detail line (or its trailing column) can show.
    enum Field: Hashable, Sendable {
        /// What the tab is ("Terminal", "Browser", "Agent chat").
        case kind
        /// The terminal's folder, or the page's host.
        case place
        /// The terminal's git branch.
        case branch
        /// The tab's status word ("Working", "Needs input"), nothing when idle.
        case state
        /// How long ago the tab last had activity ("12m").
        case time
        /// The model an agent chat runs on.
        case model
        /// The program a terminal runs now.
        case command
        /// Where an agent chat or terminal runs: "This Mac", "Cloud" or the machine's name (Leo
        /// 2026-11-01: "local or nonlocal is probably useful to see in the hover previews").
        case machine
    }

    /// What the card's top line holds.
    enum Header: Hashable, Sendable {
        /// The workspace's icon and name.
        case plain
        /// The name, then a muted line with the tab count, the running tabs and the unread ones.
        case summary
    }

    /// The card's fill.
    enum Material: Hashable, Sendable {
        /// The shared hover card glass shows through.
        case glass
        /// The glass under a veil of the theme's window background at 0.55: readable over a busy
        /// terminal, still glass (Leo 2026-10-21, `check-overlay-glass.py`: "STOP DOING SOLID").
        case frosted
    }

    /// Two lines per tab (title over its detail line), or one (the detail after the title).
    var twoLines = true
    /// The detail line's facts, in order; empty facts are skipped. A row with none shows its kind.
    var detail: [Field] = [.command, .place, .model, .state, .machine, .time]
    /// Whether a tab on this Mac names it too ("This Mac"), or only a tab elsewhere names its machine.
    var namesLocalMachine = true
    /// A text column at the row's trailing end, before the status mark; nil for none.
    var trailing: Field?
    /// Tabs listed under a muted kind label (terminals, agents, pages), each group in its tabs' order.
    var groupsByKind = false
    var header: Header = .plain
    var material: Material = .frosted
    /// How many tabs show before "Show N more".
    var rowLimit = 4
    /// The state word in its status color (needs input orange, error red).
    var tintsState = false

    /// The shipped card: compact two-line rows (icon, title, one muted line: command · place · model ·
    /// state · machine · time, each when the tab has it) on one text column, on the frosted glass.
    static let standard = WorkspaceTabHoverCardStyle()

    /// A row's height: the title and detail lines plus a step above and below.
    @MainActor var rowHeight: CGFloat { twoLines ? 34 : 24 }
}
