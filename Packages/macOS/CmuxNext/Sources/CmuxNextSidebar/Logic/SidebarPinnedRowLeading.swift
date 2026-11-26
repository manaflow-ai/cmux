public import CmuxNextDesign

/// What a pinned workspace row with its own icon or color dot draws in the leading icon column, under Home's glyph
/// (Debug `sidebar.pinnedRowLeading`). A pinned row with neither always draws its pin there.
///
/// https://github.com/manaflow-ai/cmux/issues/38061: Home's label and the pinned rows' titles must start at one x. With
/// the pin first and the row's own icon one column after it, a pinned "🚀 Rocket" title started 29.5 pt right of
/// "Home" (measured on a tagged build), so only the text-only pinned rows lined up.
public nonisolated enum SidebarPinnedRowLeading: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The default: the row's own icon (an emoji, a symbol, a favicon) or color dot takes the leading column in the
    /// pin's place, its ink centered as Home's glyph is, and the title starts at Home's label x. The Pinned section
    /// already says the row is pinned.
    case ownIcon
    /// The look before #38061's second pass: the pin in the leading column, the row's own icon or dot one column
    /// after it, and the title after that, one column right of Home's label. Kept for comparison.
    case pinThenIcon

    public var tunableTitle: String {
        switch self {
        case .ownIcon: "Own icon in the pin's place"
        case .pinThenIcon: "Pin, then the row's icon"
        }
    }

    public static let tunable = Tunable<SidebarPinnedRowLeading>.choice(
        "sidebar.pinnedRowLeading", .sidebar, "Pinned row leading glyph",
        help: "What a pinned workspace with its own icon or color draws under Home's glyph: that icon, so its title lines up with Home's label (default), or the pin with the icon after it.",
        default: .ownIcon, code: "SidebarPinnedRowLeading.tunable")
}
