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

public struct Metrics {
    public init() {}
    /// Applies the live app-wide scale to a chrome metric.
    public static func scale(_ value: CGFloat) -> CGFloat { value * DesignSettings.shared.uiScale }
    /// Active density, read from `DesignSettings.shared`. Reading any metric
    /// inside an Observation-tracked scope (view layout, `withObservationTracking`)
    /// registers a dependency, so a density or override change re-lays out live.
    public static var density: Density { DesignSettings.shared.density }

    /// The density preset, or the user's `appearance.metrics.*` override.
    /// Debug Settings overrides apply on top (`MetricTunable`).
    static func pick(_ compact: CGFloat, _ comfortable: CGFloat, _ key: MetricKey? = nil) -> CGFloat {
        if let key, let value = DesignSettings.shared.overrides[key] { return value }
        return density == .compact ? compact : comfortable
    }

    // MARK: Window chrome

    /// Default sidebar width when visible.
    public static var sidebarWidth: CGFloat { MetricTunables.sidebarWidth.value }
    public static var sidebarMinWidth: CGFloat { scale(ChromeTunables.sidebarMinWidth.value) }
    public static var sidebarMaxWidth: CGFloat { scale(ChromeTunables.sidebarMaxWidth.value) }

    /// Height of the unified titlebar area. The tab strip sits beside the
    /// traffic lights inside it.
    public static var titlebarHeight: CGFloat { MetricTunables.titlebarHeight.value }

    /// Height of a pane's tab strip.
    public static var tabStripHeight: CGFloat { MetricTunables.tabStripHeight.value }

    /// Space reserved at the leading edge of the titlebar for traffic lights.
    public static var trafficLightInset: CGFloat { scale(ChromeTunables.trafficLightInset.value) }

    // MARK: Rows and tabs

    /// Sidebar workspace row with one line of text.
    public static var sidebarRowHeight: CGFloat { MetricTunables.sidebarRowHeight.value }
    /// Sidebar workspace row with a subtitle line (cwd, branch, agent status).
    public static var sidebarRowHeightWithSubtitle: CGFloat { MetricTunables.sidebarRowHeightWithSubtitle.value }
    /// Sidebar group / machine section header.
    public static var sidebarHeaderHeight: CGFloat { MetricTunables.sidebarHeaderHeight.value }

    public static var tabHeight: CGFloat { MetricTunables.tabHeight.value }
    public static var tabMaxWidth: CGFloat { MetricTunables.tabMaxWidth.value }
    /// Icon-only width (pinned tabs and fully shrunk tabs).
    public static var tabMinWidth: CGFloat { MetricTunables.tabMinWidth.value }

    public static var paletteRowHeight: CGFloat { MetricTunables.paletteRowHeight.value }
    public static var paletteSearchHeight: CGFloat { MetricTunables.paletteSearchHeight.value }
    public static var paletteWidth: CGFloat { MetricTunables.paletteWidth.value }

    // MARK: Spacing (2 pt grid)

    public static var space1: CGFloat { scale(ChromeTunables.space1.value) }
    public static var space2: CGFloat { scale(ChromeTunables.space2.value) }
    public static var space3: CGFloat { scale(ChromeTunables.space3.value) }
    public static var space4: CGFloat { scale(ChromeTunables.space4.value) }
    public static var space5: CGFloat { scale(ChromeTunables.space5.value) }
    public static var space6: CGFloat { scale(ChromeTunables.space6.value) }

    /// Inset between the window edge and floating glass panels.
    public static var panelInset: CGFloat { MetricTunables.panelInset.value }
    /// Gap between strip columns.
    public static var columnGap: CGFloat { MetricTunables.columnGap.value }
    /// Divider thickness between split panes (hit area is wider).
    /// A room dot at the bottom of the sidebar (drawn size; its hit target
    /// is `roomDotSlot` wide and the bar's full height).
    public static var roomDotDiameter: CGFloat { MetricTunables.roomDotDiameter.value }
    public static var roomDotSlot: CGFloat { MetricTunables.roomDotSlot.value }

    /// Height of the fade at a scrolling list's top or bottom edge while
    /// content is hidden beyond it (`ScrollEdgeFade`).
    public static var scrollEdgeFade: CGFloat { MetricTunables.scrollEdgeFade.value }

    public static var dividerThickness: CGFloat { scale(ChromeTunables.dividerThickness.value) }
    /// Width of the sidebar's resting edge line (`sidebar.border`,
    /// `sidebar.borderWidth`); 0 when off or under `appearance.borders` none.
    public static var sidebarBorderWidth: CGFloat {
        let border = DesignSettings.shared.sidebarBorder
        return border.shows ? lineWidth(border.width.map(scale) ?? dividerThickness) : 0
    }
    public static var dividerHitWidth: CGFloat { scale(ChromeTunables.dividerHitWidth.value) }

    /// Inset around every pane's tab strip and content (`layout.panePadding`;
    /// 0 is edge to edge).
    public static var panePadding: CGFloat { scale(ChromeTunables.panePadding.resolve(codePanePadding)) }
    /// `layout.panePadding`, else the density default (no Debug Settings override).
    static var codePanePadding: CGFloat {
        let chrome = DesignSettings.shared.paneChrome
        return chrome.padding ?? PaneSeparation.resolve(chrome).impliedPadding ?? (density == .compact ? 2 : 4)
    }

    // MARK: Pane alignment

    // A pane's tab pills and toolbar button shapes start on its content
    // border's left edge (the chrome line), and the terminal's first cell
    // sits `PaneChromeMetrics.terminalTextInset` inside it (dogfood
    // 2026-10-01, replacing nxdog12's separate content line).

    /// Half the gap between neighboring tab pills. Each pill leaves the
    /// whole gap at its trailing side, so the first pill starts on the
    /// chrome line.
    public static var tabBackgroundInset: CGFloat { scale(ChromeTunables.tabBackgroundInset.value) }
    /// Inset of a tab's icon from its pill's leading edge.
    public static var tabContentLeadingInset: CGFloat { scale(ChromeTunables.tabContentLeadingInset.value) }
    /// The chrome line: tab pills and toolbar button shapes, from the
    /// content border's left edge.
    public static var paneChromeInset: CGFloat { PaneChromeMetrics.pillLeading }

    // MARK: Shape

    /// Corner radius of a pane's rounded rect (`layout.paneCornerRadius`; 0 is
    /// square). Without padding and border the default is 0, so panes are
    /// exactly edge to edge unless the radius is set explicitly.
    public static var paneCornerRadius: CGFloat {
        let chrome = DesignSettings.shared.paneChrome
        if let radius = chrome.cornerRadius { return scale(radius) }
        if panePadding == 0 && paneBorder == .none { return 0 }
        return densityPaneCornerRadius
    }
    /// The density's rounded pane corner radius, used when padding or a
    /// border shows and `layout.paneCornerRadius` is unset.
    public static var densityPaneCornerRadius: CGFloat { MetricTunables.densityPaneCornerRadius.value }
    /// How panes are told apart (`layout.paneSeparation`, else the legacy
    /// `layout.paneBorder` and padding).
    public static var paneSeparation: PaneSeparation { PaneSeparation.resolve(DesignSettings.shared.paneChrome) }
    /// Pane border: subtle only for the `borders` separation, and none
    /// under `appearance.borders` none. The line is one device pixel wide.
    public static var paneBorder: PaneBorderStyle {
        Borders.drawsLines && paneSeparation.drawsPaneBorder ? .subtle : .none
    }

    /// A border, hairline or stroke of `width` points: 0 under
    /// `appearance.borders` none (`Borders`).
    public static func lineWidth(_ width: CGFloat) -> CGFloat { Borders.width(width) }
    /// Pane border width in points (`layout.paneBorderWidth`); nil is one
    /// device pixel.
    public static var paneBorderWidth: CGFloat? { DesignSettings.shared.paneChrome.borderWidth.map(scale) }

    /// Corner radius for floating glass panels (sidebar, palette).
    public static var panelCornerRadius: CGFloat { MetricTunables.panelCornerRadius.value }
    /// Corner radius for tabs and rows.
    public static var itemCornerRadius: CGFloat { MetricTunables.itemCornerRadius.value }
    /// Corner radius for a small labeled surface (a note, toast or count
    /// badge) of `height`: the item radius, never a capsule.
    public static func chipCornerRadius(height: CGFloat) -> CGFloat {
        min(itemCornerRadius, (height / 4).rounded(.down))
    }

    // MARK: Icons

    public static var iconSize: CGFloat { MetricTunables.iconSize.value }
    public static var smallIconSize: CGFloat { MetricTunables.smallIconSize.value }
}

/// Type scale. Compact uses 12 pt body in chrome (terminal fonts come from
/// the Ghostty config and are not affected).
public struct Typography {
    public init() {}
    private static var compact: Bool { Metrics.density == .compact }
    /// User override for chrome body size; other styles scale from it.
    private static var scale: CGFloat {
        guard let body = DesignSettings.shared.overrides[.chromeFontSize] else { return DesignSettings.shared.uiScale }
        return body / (compact ? 12 : 13) * DesignSettings.shared.uiScale
    }
    /// The user's text size relative to the density's body size (1 when
    /// Interface Size is not overridden). Surfaces with their own type scale
    /// (the Home transcript's `textScale`) follow it.
    public static var userScale: CGFloat { scale }
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
    /// Page titles in windows that introduce something (onboarding).
    public static var title: NSFont { .systemFont(ofSize: size(20, 22), weight: .semibold) }
    /// The line under a page title.
    public static var subtitle: NSFont { .systemFont(ofSize: size(13, 14), weight: .regular) }
}
