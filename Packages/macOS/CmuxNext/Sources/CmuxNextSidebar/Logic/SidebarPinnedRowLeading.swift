public import CmuxNextDesign

/// What a pinned workspace row or pinned group with its own icon or color dot draws in the leading icon column, under
/// Home's glyph (Debug `sidebar.pinnedRowLeading`). A pinned row with neither always draws its pin there.
///
/// https://github.com/manaflow-ai/cmux/issues/38061 put the row's own icon in the pin's place so its title started at
/// Home's label x. A pinned row with a site favicon ("Spotify", "standup") then showed no pin at all, so it read as an
/// ordinary workspace (2026-11-16, https://github.com/manaflow-ai/cmux/issues/42431). Every pinned row now keeps its
/// pin under Home's glyph, with its own icon in the next column.
public nonisolated enum SidebarPinnedRowLeading: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The row's own icon (an emoji, a symbol, a favicon) or color dot takes the leading column in the pin's place, and
    /// the title starts at Home's label x. The row draws no pin. Kept for comparison.
    case ownIcon
    /// The default: the pin in the leading column, centered under Home's glyph, the row's own icon or dot centered in
    /// the next column, and the title after that, one column right of Home's label.
    case pinThenIcon

    public var tunableTitle: String {
        switch self {
        case .ownIcon: "Own icon in the pin's place"
        case .pinThenIcon: "Pin, then the row's icon"
        }
    }

    public static let tunable = Tunable<SidebarPinnedRowLeading>.choice(
        "sidebar.pinnedRowLeading", .sidebar, "Pinned row leading glyph",
        help: "What a pinned workspace or group with its own icon or color draws under Home's glyph: the pin with the icon after it (default), or that icon in the pin's place, so its title lines up with Home's label but the row shows no pin.",
        default: .pinThenIcon, code: "SidebarPinnedRowLeading.tunable")
}
