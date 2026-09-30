public import AppKit

/// Layout constants shared by chrome components.
///
/// Compact is the default density: dense like a pro tool, but every value
/// sits on a 2 pt grid with consistent optical rhythm so it still reads as
/// designed. `Density.comfortable` exists for users who opt in; modules read
/// metrics through `Metrics` so a density switch changes every surface.
public enum Density: String, Sendable, CaseIterable, Codable {
    case compact
    case comfortable
}

public enum Metrics {
    /// Active density, read from `DesignSettings.shared`. Reading any metric
    /// inside an Observation-tracked scope (view layout, `withObservationTracking`)
    /// registers a dependency, so a density or override change re-lays out live.
    public static var density: Density { DesignSettings.shared.density }

    private static func pick(_ compact: CGFloat, _ comfortable: CGFloat, _ key: MetricKey? = nil) -> CGFloat {
        if let key, let value = DesignSettings.shared.overrides[key] { return value }
        return density == .compact ? compact : comfortable
    }

    // MARK: Window chrome

    /// Default sidebar width when visible.
    public static var sidebarWidth: CGFloat { pick(208, 240, .sidebarWidth) }
    public static var sidebarMinWidth: CGFloat { 160 }
    public static var sidebarMaxWidth: CGFloat { 360 }
    /// Width of the icons-only collapsed sidebar.
    public static var sidebarCollapsedWidth: CGFloat { pick(44, 52) }

    /// Height of the unified titlebar area. The tab strip sits beside the
    /// traffic lights inside it.
    public static var titlebarHeight: CGFloat { pick(32, 40) }

    /// Height of a pane's tab strip.
    public static var tabStripHeight: CGFloat { pick(28, 36, .tabStripHeight) }

    /// Space reserved at the leading edge of the titlebar for traffic lights.
    public static let trafficLightInset: CGFloat = 76

    // MARK: Rows and tabs

    /// Sidebar workspace row with one line of text.
    public static var sidebarRowHeight: CGFloat { pick(24, 32, .sidebarRowHeight) }
    /// Sidebar workspace row with a subtitle line (cwd, branch, agent status).
    public static var sidebarRowHeightWithSubtitle: CGFloat { pick(36, 46) }
    /// Sidebar group / machine section header.
    public static var sidebarHeaderHeight: CGFloat { pick(22, 26) }

    public static var tabHeight: CGFloat { pick(24, 30) }
    public static var tabMaxWidth: CGFloat { pick(200, 240, .tabMaxWidth) }
    /// Icon-only width (pinned tabs and fully shrunk tabs).
    public static var tabMinWidth: CGFloat { pick(32, 40) }

    public static var paletteRowHeight: CGFloat { pick(32, 40, .paletteRowHeight) }
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
    public static var columnGap: CGFloat { pick(6, 8, .columnGap) }
    /// Divider thickness between split panes (hit area is wider).
    public static let dividerThickness: CGFloat = 1
    public static let dividerHitWidth: CGFloat = 7

    // MARK: Shape

    /// Corner radius for floating glass panels (sidebar, palette).
    public static var panelCornerRadius: CGFloat { pick(10, 12, .panelCornerRadius) }
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
    /// User override for chrome body size; other styles scale from it.
    private static var scale: CGFloat {
        guard let body = DesignSettings.shared.overrides[.chromeFontSize] else { return 1 }
        return body / (compact ? 12 : 13)
    }
    private static func size(_ compactSize: CGFloat, _ comfortableSize: CGFloat) -> CGFloat {
        (compact ? compactSize : comfortableSize) * scale
    }

    /// Tab titles, sidebar rows, palette results.
    public static var body: NSFont { .systemFont(ofSize: size(12, 13), weight: .regular) }
    /// Selected or emphasized row titles.
    public static var bodyEmphasized: NSFont { .systemFont(ofSize: size(12, 13), weight: .medium) }
    /// Subtitles, shortcut hints, counts.
    public static var caption: NSFont { .systemFont(ofSize: size(10.5, 11), weight: .regular) }
    /// Section headers (uppercase is not used; weight and color carry hierarchy).
    public static var header: NSFont { .systemFont(ofSize: size(11, 12), weight: .semibold) }
    /// Palette search field.
    public static var search: NSFont { .systemFont(ofSize: size(16, 18), weight: .regular) }
    /// Shortcut glyphs.
    public static var shortcut: NSFont { .monospacedSystemFont(ofSize: size(10.5, 11), weight: .medium) }
}
