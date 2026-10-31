public import CmuxNextDesign

/// SCRATCH mockup (archived-variations gallery, Lawrence 2026-10-30): how the sidebar draws archived
/// workspaces (`sidebar.archivedLook`, Debug Settings only). `dim` is what ships: the row stays last in
/// its group, dimmed. The others are design proposals for less vertical space; none lands until picked.
public nonisolated enum SidebarArchivedLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// Today: archived rows stay last in their group, dimmed.
    case dim
    /// A: one "Archived (N)" fold row at the end of each group; a click opens it.
    case groupFold
    /// B: archived rows leave their groups; one "Archived (N)" row at the sidebar's end.
    case globalRow
    /// C: archived rows hidden; the group header says "N archived" after its name.
    case headerCount
    /// D: archived rows hidden everywhere; Restore Archived (palette, sidebar menu) finds them.
    case hidden
    /// E: archived rows stay in place, one short line each.
    case compact
    /// F: a small "··· N archived" line at the end of each group.
    case dots
    /// G: an "Active / All" filter at the top of the list; Active hides archived rows.
    case filter
    /// H: one row at the group's end with the archived rows' initials stacked, then the count.
    case pile

    public var tunableTitle: String {
        switch self {
        case .dim: "Dimmed in place (today)"
        case .groupFold: "A: Archived (N) fold per group"
        case .globalRow: "B: One Archived row at the bottom"
        case .headerCount: "C: Count in the group header"
        case .hidden: "D: Hidden (Restore Archived page)"
        case .compact: "E: Compact one-line rows"
        case .dots: "F: Small ··· N line per group"
        case .filter: "G: Active / All filter"
        case .pile: "H: Stacked pile row"
        }
    }

    /// The look takes archived rows out of their list (they show elsewhere, or not at all).
    var removesRows: Bool {
        switch self {
        case .dim, .compact: false
        case .groupFold, .globalRow, .headerCount, .hidden, .dots, .filter, .pile: true
        }
    }

    /// The look draws one row at the end of each list that had archived rows.
    var foldsPerList: Bool { self == .groupFold || self == .dots || self == .pile }
}

/// SCRATCH mockup: what a mock row (keyed as a Done fold row) draws instead of "Done (N)".
public nonisolated struct SidebarArchiveMockRow: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// "Archived (N)" with a chevron (A, B).
        case fold
        /// "··· N archived", small (F).
        case dots
        /// Stacked initials and "N archived" (H).
        case pile
        /// "Active  All N" segmented filter (G).
        case filter
        /// "N idle · Archive" tidy-up hint row (Tidy Up variant).
        case tidy
    }

    public var kind: Kind
    public var count: Int
    /// The archived rows' titles, for the pile's initials.
    public var titles: [String]

    public init(kind: Kind, count: Int, titles: [String] = []) {
        self.kind = kind
        self.count = count
        self.titles = titles
    }
}

/// SCRATCH mockup (archived-variations gallery): the Tidy Up suggestion's variant (`sidebar.archivedTidy`).
public nonisolated enum SidebarArchivedTidy: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// No mock: the app's own card, if any.
    case off
    /// "Archive 3 idle workspaces?" with Archive and Always Archive; the x is Not Now.
    case card
    /// "3 idle workspaces" with a text button Archive in the x's place.
    case oneLine
    /// Archive and an inline "Always" switch on one row; the x is Not Now.
    case toggle
    /// No card: a "3 idle · Archive" row at the list's end.
    case rowHint
    /// No card: a toast "Archived 3 idle workspaces" with Undo (auto-archive on).
    case toast

    public var tunableTitle: String {
        switch self {
        case .off: "Off"
        case .card: "Card: Archive / Always Archive"
        case .oneLine: "One-line card"
        case .toggle: "Card with Always switch"
        case .rowHint: "Hint row at the list's end"
        case .toast: "Toast only"
        }
    }
}
