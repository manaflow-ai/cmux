/// How a workspace row shows what waits in it (Debug Settings `sidebar.rowBadge`). Leo and
/// Lawrence 2026-10-14: no count numbers on NEXT rows. The default follows T3 Code's thread list:
/// the row leads with its harness logo or kind icon, and one small badge on that icon's corner says
/// the most urgent state; the count reads in the hover card. `stack` is Leo's alternative, one
/// glyph per pending item overlapping in the trailing slot; `trailing` keeps the count badge and
/// the trailing status glyph (the look before); `status` drops the kind icon and badge for one
/// status icon on a side, and tabs follow it (`StatusIndicatorConfig.statusSide`).
public nonisolated enum SidebarRowBadgeStyle: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// One badge on the leading icon's bottom-right corner.
    case corner
    /// Overlapping glyphs in the trailing slot, one per pending item, up to `SidebarRowBadgeStackCap`.
    case stack
    /// The count badge and the trailing status glyph.
    case trailing
    /// No kind icon and no badge: one status icon (the most urgent state) on the side
    /// `SidebarStatusIconSide` names; tabs draw theirs the same way (Leo and Lawrence 2026-10-14).
    case status

    public var tunableTitle: String {
        switch self {
        case .corner: "Corner badge on the icon"
        case .stack: "Glyph stack (one per item)"
        case .trailing: "Count and trailing glyph (before)"
        case .status: "Status icon on the left or right"
        }
    }

    public static let tunable = Tunable<SidebarRowBadgeStyle>.choice(
        "sidebar.rowBadge", .sidebar, "Row badge",
        help: "How a workspace row shows unread items and agent states: a badge on the leading icon's corner, a stack of glyphs, the count with a trailing glyph, or one status icon on the side Status Icon Side names, on rows and tabs alike.",
        default: .corner, code: "SidebarRowBadgeStyle.tunable")
}
