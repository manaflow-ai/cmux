public import CmuxNextDesign

/// Where a row's leading glyph sits in the sidebar's one icon column (Debug `sidebar.leadingColumn`).
///
/// The column's box starts at the row inset at every density (`SidebarStyle.iconColumnBox` wide), and a title after
/// a glyph starts at one text x after it. The looks differ in where the glyph's ink sits in that box, and whether a
/// text-only row keeps the box empty.
public nonisolated enum SidebarLeadingColumnLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The default (Lawrence msg 19643, "left alignment here is bad"): every glyph's ink (a pin, Home's house, a
    /// favicon, an emoji, a symbol) starts at the row inset, on the left edge text-only titles start on.
    case inset
    /// As `inset`, and a text-only row keeps the icon column empty, so every title starts at the one text x. Takes
    /// back Lawrence msg 11405 ("text needs to be as left as possible"); kept for comparison only.
    case slotted
    /// Before msg 19643: each glyph's ink centers in the column (Leo 2026-10-28, "the alignment"), so a narrow pin
    /// starts about 5 pt right of the inset and Home's house about 2 pt.
    case centered

    public var tunableTitle: String {
        switch self {
        case .inset: "Glyphs start at the row inset"
        case .slotted: "Glyphs at the inset, empty slot on text rows"
        case .centered: "Glyphs centered in the icon column"
        }
    }

    public static let tunable = Tunable<SidebarLeadingColumnLook>.choice(
        "sidebar.leadingColumn", .sidebar, "Leading column",
        help: "Where a row's leading glyph sits in the icon column: its ink at the row inset (default), the same with an empty icon slot on text-only rows, or centered in the column.",
        default: .inset, code: "SidebarLeadingColumnLook.tunable")
}
