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

    public static let all: [LayoutMetricSetting] = [sidebarWidth, sidebarRowHeight, columnGap, dividerThickness, dividerHitWidth, titlebarHeight] + tabBar + tabWidths

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
