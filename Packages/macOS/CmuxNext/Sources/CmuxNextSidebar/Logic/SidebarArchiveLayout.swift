public import CmuxNextDesign

/// SCRATCH mockup (archive-layout gallery round 2, Lawrence msg 19197, 2026-10-31): where archived workspaces and
/// archived groups go in the sidebar (`sidebar.archiveLayout`, Debug Settings only). Only the `archiveLayout` scenario
/// of `debug.sidebar_nested_fixture` reads it; `today` is what ships. Not for merge.
public nonisolated enum SidebarArchiveLayout: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// A: today: an "Archived (N)" row per list, archived groups dimmed in place.
    case today
    /// B: one collapsed "Archive (N)" row at the sidebar's end; archived and fully archived groups move into it.
    case section
    /// C: B opened: the archived groups whole and the archived loose rows, dimmed, under it.
    case sectionOpen
    /// D: an "Active | Archive" switch tops the list; Active selected.
    case pageActive
    /// D: the same switch with Archive selected: the list shows only archived things.
    case pageArchive
    /// E: a per-group archive glyph and count on the header; fully archived groups go to B's row.
    case badge
    /// F: nothing in the list; a quiet "45 archived" link at its end.
    case footer
    /// G: B's row as one compact line: the archived groups' colors stacked, then the count.
    case chips
    /// H: nothing in the list; search and the palette find archived things.
    case hidden
    /// I: B as a quiet section header ("Archive", count), the macOS sidebar section idiom.
    case header
    /// J: B opened to the three latest archived rows, then "Show all N" (an undo trail).
    case peek

    public var tunableTitle: String {
        switch self {
        case .today: "A: Archived (N) per list (today)"
        case .section: "B: One Archive section at the end"
        case .sectionOpen: "C: Archive section opened"
        case .pageActive: "D: Active | Archive switch (Active)"
        case .pageArchive: "D: Active | Archive switch (Archive)"
        case .badge: "E: Count badge on the group header"
        case .footer: "F: Footer link only"
        case .chips: "G: Compact line with color chips"
        case .hidden: "H: Hidden (search and palette only)"
        case .header: "I: Quiet section header"
        case .peek: "J: Section with the latest three"
        }
    }

    /// Archived workspace rows draw dimmed in place (no "Archived (N)" fold): the archive's own rows (C, J).
    var drawsArchivedInPlace: Bool { self == .sectionOpen || self == .peek || self == .pageArchive }
}

/// SCRATCH mockup: what the `archiveLayout` fixture tells the layout (`SidebarLayoutOptions/archiveMock`).
public nonisolated struct SidebarArchiveMockInfo: Hashable, Sendable {
    public var layout: SidebarArchiveLayout
    /// Archived workspaces in all (loose, in archived groups, and archived members of other groups).
    public var total: Int
    /// The archived groups' colors (archived, or every member archived), for G's chips.
    public var colors: [GroupColor]

    public init(layout: SidebarArchiveLayout, total: Int, colors: [GroupColor]) {
        self.layout = layout
        self.total = total
        self.colors = colors
    }
}

/// SCRATCH mockup: what a mock row, keyed as a Done fold row, draws instead of "Done (N)".
public nonisolated struct SidebarArchiveMockRow: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Box glyph, "Archive", the count, a chevron (B, C, E, J).
        case section(open: Bool)
        /// "Active | Archive N" segmented switch (D).
        case switcher(archiveSelected: Bool)
        /// A quiet "N archived ›" link (F).
        case footer
        /// Stacked group color chips, "Archive", the count (G).
        case chips
        /// A section header: "Archive" small and quiet, the count on the right (I).
        case header
        /// "Show all N archived" (J).
        case showAll
    }

    public var kind: Kind
    public var count: Int
    public var colors: [GroupColor]

    public init(kind: Kind, count: Int, colors: [GroupColor] = []) {
        self.kind = kind
        self.count = count
        self.colors = colors
    }
}
