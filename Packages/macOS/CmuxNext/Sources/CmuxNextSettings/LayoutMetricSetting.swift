import CmuxNextDesign
import CoreGraphics

/// The `appearance.metrics.<name>` keys the schema lists besides the interface size (which has its
/// own `InterfaceSizeSetting`): sizes in points whose default is the density's. cmux-next and
/// cmux-browser both read them. Each `range` must equal `DesignSettings.allowedRange` and each
/// default its `MetricTunables` preset, or for `tabFontSize` Chrome's 12 pt at every density (kept by hand:
/// this module reads no main-actor state).
public nonisolated struct LayoutMetricSetting: Sendable, Hashable {
    /// The `MetricKey` raw value.
    public let name: String
    public let range: ClosedRange<Double>
    public let compact: Double
    public let comfortable: Double

    public var configPath: [String] { ["appearance", "metrics", name] }

    /// The Appearance rows' ranges and compact values (their Settings placeholders) come from
    /// schemas/settings/source/appearance.json (SettingsSchema+Appearance.generated.swift).
    public static let sidebarWidth = LayoutMetricSetting(name: "sidebarWidth", range: sidebarWidthRange, compact: sidebarWidthPlaceholder, comfortable: 240)
    public static let columnGap = LayoutMetricSetting(name: "columnGap", range: columnGapRange, compact: columnGapPlaceholder, comfortable: 8)
    public static let dividerThickness = LayoutMetricSetting(name: "dividerThickness", range: dividerThicknessRange, compact: dividerThicknessPlaceholder,
                                                             comfortable: 1)
    public static let dividerHitWidth = LayoutMetricSetting(name: "dividerHitWidth", range: dividerHitWidthRange, compact: dividerHitWidthPlaceholder,
                                                            comfortable: 7)
    public static let titlebarHeight = LayoutMetricSetting(name: "titlebarHeight", range: titlebarHeightRange, compact: titlebarHeightPlaceholder,
                                                           comfortable: 40)
    /// Center-to-center spacing for the Space buttons in either sidebar placement.
    public static let spaceButtonSpacing = LayoutMetricSetting(name: "spaceButtonSpacing", range: spaceButtonSpacingRange,
                                                               compact: spaceButtonSpacingPlaceholder, comfortable: 32)
    /// The workspace row height, shared with tabs and browser controls through `Metrics.chromeRowHeight`.
    /// Unset, the app density supplies it. Explicit tab sizing still takes precedence for tabs.
    public static let sidebarRowHeight = LayoutMetricSetting(name: "sidebarRowHeight", range: sidebarRowHeightRange, compact: sidebarRowHeightPlaceholder,
                                                             comfortable: 32)

    /// The tab bar rows' ranges and compact values (their Settings placeholders) come from
    /// schemas/settings/source/tabs.json (SettingsSchema+Tabs.generated.swift).
    /// The tab strip's widths (the Tabs group): the max is today's per density; the selected minimum and
    /// the pinned width are Chrome's, from the shared tokens (design-tokens.json `motion.tabStrip`); the
    /// other tabs' minimum is the favicon plus close button width.
    public static let tabMaxWidth = LayoutMetricSetting(name: "tabMaxWidth", range: tabMaxWidthRange, compact: tabMaxWidthPlaceholder, comfortable: 240)
    public static let tabMinActiveWidth = token("tabMinActiveWidth", tabMinActiveWidthRange, compact: tabMinActiveWidthPlaceholder) { $0.minActiveWidth }
    /// Room for the favicon, a few title characters and the close button (`MetricTunables.tabMinInactiveWidth`),
    /// not Chrome's 32.
    public static let tabMinInactiveWidth = LayoutMetricSetting(name: "tabMinInactiveWidth", range: tabMinInactiveWidthRange, compact: tabMinInactiveWidthPlaceholder,
                                                                  comfortable: 74)
    public static let tabPinnedWidth = token("tabPinnedWidth", tabPinnedWidthRange, compact: tabPinnedWidthPlaceholder) { $0.pinnedWidth }
    public static let tabWidths: [LayoutMetricSetting] = [tabMaxWidth, tabMinActiveWidth, tabMinInactiveWidth, tabPinnedWidth]
    /// The tab bar's height (its pills follow it, `Metrics.tabHeight`) and the tab titles' text size, apart
    /// from the interface size (https://github.com/manaflow-ai/cmux/issues/26493). Unset, the title follows
    /// the interface size; the defaults here are the density's body size.
    public static let tabStripHeight = LayoutMetricSetting(name: "tabStripHeight", range: tabStripHeightRange, compact: tabStripHeightPlaceholder, comfortable: 36)
    public static let tabFontSize = LayoutMetricSetting(name: "tabFontSize", range: tabFontSizeRange, compact: tabFontSizePlaceholder, comfortable: 12)
    public static let tabBar: [LayoutMetricSetting] = [tabStripHeight, tabFontSize]

    /// A look's proportions (Leo 2026-11-19: "the layout and proportions as well"): the sidebar row's inset, padding
    /// and gap, the toolbar buttons' size, gap and corner, the spacing grid's multiplier and the chat composer's padding
    /// and height. Unset, each is the density's, so the defaults draw today's layout.
    public static let sidebarRowInset = LayoutMetricSetting(name: "sidebarRowInset", range: sidebarRowInsetRange, compact: sidebarRowInsetPlaceholder, comfortable: 8)
    public static let sidebarRowPadding = LayoutMetricSetting(name: "sidebarRowPadding", range: sidebarRowPaddingRange, compact: sidebarRowPaddingPlaceholder,
                                                              comfortable: 8)
    public static let sidebarRowGap = LayoutMetricSetting(name: "sidebarRowGap", range: sidebarRowGapRange, compact: sidebarRowGapPlaceholder, comfortable: 2)
    public static let sidebarRowHeightWithSubtitle = LayoutMetricSetting(
        name: "sidebarRowHeightWithSubtitle", range: sidebarRowHeightWithSubtitleRange, compact: sidebarRowHeightWithSubtitlePlaceholder, comfortable: 45)
    /// Shares, not points: the active toolbar button's fill and the header divider's strength.
    public static let toolbarButtonActiveFill = LayoutMetricSetting(name: "toolbarButtonActiveFill", range: toolbarButtonActiveFillRange,
                                                                    compact: toolbarButtonActiveFillPlaceholder, comfortable: 0.14)
    public static let headerDivider = LayoutMetricSetting(name: "headerDivider", range: headerDividerRange, compact: headerDividerPlaceholder, comfortable: 0)
    public static let toolbarButtonSize = LayoutMetricSetting(name: "toolbarButtonSize", range: toolbarButtonSizeRange, compact: toolbarButtonSizePlaceholder,
                                                              comfortable: 26)
    public static let toolbarButtonGap = LayoutMetricSetting(name: "toolbarButtonGap", range: toolbarButtonGapRange, compact: toolbarButtonGapPlaceholder, comfortable: 8)
    public static let toolbarButtonCornerRadius = LayoutMetricSetting(name: "toolbarButtonCornerRadius", range: toolbarButtonCornerRadiusRange,
                                                                      compact: toolbarButtonCornerRadiusPlaceholder, comfortable: 8)
    /// A multiplier, not points: 1 keeps the density's spacing grid.
    public static let spacingScale = LayoutMetricSetting(name: "spacingScale", range: spacingScaleRange, compact: spacingScalePlaceholder, comfortable: 1)
    public static let composerPadding = LayoutMetricSetting(name: "composerPadding", range: composerPaddingRange, compact: composerPaddingPlaceholder, comfortable: 10)
    public static let composerMinHeight = LayoutMetricSetting(name: "composerMinHeight", range: composerMinHeightRange, compact: composerMinHeightPlaceholder,
                                                              comfortable: 52)
    public static let proportions: [LayoutMetricSetting] = [sidebarRowInset, sidebarRowPadding, sidebarRowGap, sidebarRowHeightWithSubtitle,
                                                            toolbarButtonSize, toolbarButtonGap, toolbarButtonCornerRadius, toolbarButtonActiveFill,
                                                            headerDivider, spacingScale, composerPadding, composerMinHeight]

    public static let all: [LayoutMetricSetting] = [
        sidebarWidth, sidebarRowHeight, spaceButtonSpacing, columnGap, dividerThickness, dividerHitWidth, titlebarHeight,
    ] + tabBar + tabWidths
        + proportions

    /// A tab strip width whose comfortable value is the shared token's; its range and compact value (the
    /// Settings placeholder) are the source's (schemas/settings/source/tabs.json).
    private static func token(_ name: String, _ range: ClosedRange<Double>, compact: Double, _ width: (MotionTabStrip) -> CGFloat) -> LayoutMetricSetting {
        LayoutMetricSetting(name: name, range: range, compact: compact, comfortable: Double(width(MotionTabStrip(comfortable: true))))
    }

    /// The range of every metric the schema lists, the interface size included, by name.
    public static var ranges: [String: ClosedRange<Double>] {
        var ranges = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.range) })
        ranges[InterfaceSizeSetting().metricName] = InterfaceSizeSetting.range
        return ranges
    }
}
