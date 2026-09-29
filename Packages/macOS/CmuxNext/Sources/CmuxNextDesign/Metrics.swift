public import AppKit

/// Layout constants shared by chrome components.
///
/// Compact is the default density: dense like a pro tool, but every value
/// sits on a 2 pt grid with consistent optical rhythm so it still reads as
/// designed. `Density.comfortable` exists for users who opt in; modules read
/// metrics through `Metrics` so a density switch changes every surface.
public enum Density: Sendable {
    case compact
    case comfortable
}

public enum Metrics {
    /// Active density. Settings may change it at launch; views must not cache
    /// derived sizes across a density change.
    public static var density: Density { .compact }

    private static func pick(_ compact: CGFloat, _ comfortable: CGFloat) -> CGFloat {
        density == .compact ? compact : comfortable
    }

    // MARK: Window chrome

    /// Default sidebar width when visible.
    public static var sidebarWidth: CGFloat { pick(208, 240) }
    public static var sidebarMinWidth: CGFloat { 160 }
    public static var sidebarMaxWidth: CGFloat { 360 }
    /// Width of the icons-only collapsed sidebar.
    public static var sidebarCollapsedWidth: CGFloat { pick(44, 52) }

    /// Height of the unified titlebar area. The tab strip sits beside the
    /// traffic lights inside it.
    public static var titlebarHeight: CGFloat { pick(32, 40) }

    /// Height of a pane's tab strip.
    public static var tabStripHeight: CGFloat { pick(28, 36) }

    /// Space reserved at the leading edge of the titlebar for traffic lights.
    public static let trafficLightInset: CGFloat = 76

    // MARK: Rows and tabs

    /// Sidebar workspace row with one line of text.
    public static var sidebarRowHeight: CGFloat { pick(26, 32) }
    /// Sidebar workspace row with a subtitle line (cwd, branch, agent status).
    public static var sidebarRowHeightWithSubtitle: CGFloat { pick(38, 46) }
    /// Sidebar group / machine section header.
    public static var sidebarHeaderHeight: CGFloat { pick(22, 26) }

    public static var tabHeight: CGFloat { pick(24, 30) }
    public static var tabMaxWidth: CGFloat { pick(200, 240) }
    /// Icon-only width (pinned tabs and fully shrunk tabs).
    public static var tabMinWidth: CGFloat { pick(32, 40) }

    public static var paletteRowHeight: CGFloat { pick(32, 40) }
    public static var paletteSearchHeight: CGFloat { pick(44, 52) }
    public static var paletteWidth: CGFloat { pick(640, 720) }

    // MARK: Spacing (2 pt grid)

    public static let space1: CGFloat = 2
    public static let space2: CGFloat = 4
    public static let space3: CGFloat = 6
    public static let space4: CGFloat = 8
    public static let space5: CGFloat = 12
    public static let space6: CGFloat = 16

    /// Inset between the window edge and floating glass panels.
    public static var panelInset: CGFloat { pick(6, 8) }
    /// Gap between niri columns.
    public static var columnGap: CGFloat { pick(6, 8) }
    /// Divider thickness between split panes (hit area is wider).
    public static let dividerThickness: CGFloat = 1
    public static let dividerHitWidth: CGFloat = 7

    // MARK: Shape

    /// Corner radius for floating glass panels (sidebar, palette).
    public static var panelCornerRadius: CGFloat { pick(10, 12) }
    /// Corner radius for tabs and rows.
    public static var itemCornerRadius: CGFloat { pick(6, 7) }

    // MARK: Icons

    public static var iconSize: CGFloat { pick(14, 16) }
    public static var smallIconSize: CGFloat { pick(12, 14) }
}

/// Type scale. Compact uses 12 pt body in chrome (terminal fonts come from
/// the Ghostty config and are not affected).
public enum Typography {
    private static var compact: Bool { Metrics.density == .compact }

    /// Tab titles, sidebar rows, palette results.
    public static var body: NSFont { .systemFont(ofSize: compact ? 12 : 13, weight: .regular) }
    /// Selected or emphasized row titles.
    public static var bodyEmphasized: NSFont { .systemFont(ofSize: compact ? 12 : 13, weight: .medium) }
    /// Subtitles, shortcut hints, counts.
    public static var caption: NSFont { .systemFont(ofSize: compact ? 10.5 : 11, weight: .regular) }
    /// Section headers (uppercase is not used; weight and color carry hierarchy).
    public static var header: NSFont { .systemFont(ofSize: compact ? 11 : 12, weight: .semibold) }
    /// Palette search field.
    public static var search: NSFont { .systemFont(ofSize: compact ? 16 : 18, weight: .regular) }
    /// Shortcut glyphs.
    public static var shortcut: NSFont { .monospacedSystemFont(ofSize: compact ? 10.5 : 11, weight: .medium) }
}
