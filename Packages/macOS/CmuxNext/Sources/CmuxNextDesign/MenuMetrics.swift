public import CoreGraphics

/// The one row grid of every cmux NEXT menu, shared with the webviews' `--cmux-menu-*` tokens: in
/// points from the menu's leading edge (`trailing` from its trailing edge). The values are
/// schemas/menu-metrics/menu-metrics.json's; `gen-menu-metrics.py --check` fails when they differ.
public nonisolated struct MenuMetrics: Sendable {
    public init() {}

    /// The hover highlight's distance from the menu's edges.
    public static let highlightInset: CGFloat = 5
    /// The hover highlight's corner radius.
    public static let highlightRadius: CGFloat = 5
    /// A separator's distance from the menu's edges, on both sides: AppKit's own, where a row's content starts.
    public static let separatorInset: CGFloat = 15
    /// A checkmark or dash, in a menu that has one.
    public static let stateX: CGFloat = 10
    /// Where a row's icon starts in a menu with a checkmark or dash.
    public static let stateIconX: CGFloat = 22
    /// Where a row's icon starts (its title without an icon column): AppKit's own leading.
    public static let iconX: CGFloat = 15
    /// The box an icon fits in, its shape kept.
    public static let iconSize: CGFloat = 14
    /// Between the icon column and the text.
    public static let iconGap: CGFloat = 6
    /// A shortcut's or submenu chevron's distance from the trailing edge.
    public static let trailing: CGFloat = 12
    /// The least room between a title and its shortcut or chevron.
    public static let shortcutGap: CGFloat = 28

    /// Where a row's icon starts: after the state column when any row of the menu has a checkmark or dash.
    public static func iconX(stateColumn: Bool) -> CGFloat { stateColumn ? stateIconX : iconX }

    /// The text column: after the icon column when any row of the menu has an icon, else on it.
    public static func textX(iconColumn: Bool, stateColumn: Bool = false) -> CGFloat {
        iconX(stateColumn: stateColumn) + (iconColumn ? iconSize + iconGap : 0)
    }
}
