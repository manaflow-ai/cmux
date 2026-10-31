import CmuxNextDesign
import CoreGraphics

/// The `appearance.metrics.<name>` keys the schema lists besides the interface size (which has its
/// own `InterfaceSizeSetting`): sizes in points whose default is the density's. cmux-next and
/// cmux-browser both read them. Each `range` must equal `DesignSettings.allowedRange` and each
/// default its `MetricTunables` preset, or for `tabFontSize` the density's body size (kept by hand:
/// this module reads no main-actor state).
public nonisolated struct LayoutMetricSetting: Sendable, Hashable {
    /// The `MetricKey` raw value.
    public let name: String
    public let range: ClosedRange<Double>
    public let compact: Double
    public let comfortable: Double

    public var configPath: [String] { ["appearance", "metrics", name] }

    public static let sidebarWidth = LayoutMetricSetting(name: "sidebarWidth", range: 160...420, compact: 208, comfortable: 240)
    public static let columnGap = LayoutMetricSetting(name: "columnGap", range: 0...24, compact: 6, comfortable: 8)
    public static let dividerThickness = LayoutMetricSetting(name: "dividerThickness", range: 0...6, compact: 1, comfortable: 1)
    public static let dividerHitWidth = LayoutMetricSetting(name: "dividerHitWidth", range: 1...24, compact: 7, comfortable: 7)
    public static let titlebarHeight = LayoutMetricSetting(name: "titlebarHeight", range: 24...56, compact: 32, comfortable: 40)

    /// The tab strip's widths (the Tabs group): the max is today's per density; the selected minimum and
    /// the pinned width are Chrome's, from the shared tokens (design-tokens.json `motion.tabStrip`); the
    /// other tabs' minimum is the favicon plus close button width.
    public static let tabMaxWidth = LayoutMetricSetting(name: "tabMaxWidth", range: 120...320, compact: 200, comfortable: 240)
    public static let tabMinActiveWidth = token("tabMinActiveWidth", 32...320) { $0.minActiveWidth }
    /// Room for the favicon and the close button (`MetricTunables.tabMinInactiveWidth`), not Chrome's 32.
    public static let tabMinInactiveWidth = LayoutMetricSetting(name: "tabMinInactiveWidth", range: 16...320, compact: 48, comfortable: 50)
    public static let tabPinnedWidth = token("tabPinnedWidth", 24...120) { $0.pinnedWidth }
    public static let tabWidths: [LayoutMetricSetting] = [tabMaxWidth, tabMinActiveWidth, tabMinInactiveWidth, tabPinnedWidth]
    /// The tab bar's height (its pills follow it, `Metrics.tabHeight`) and the tab titles' text size, apart
    /// from the interface size (https://github.com/manaflow-ai/cmux/issues/26493). Unset, the title follows
    /// the interface size; the defaults here are the density's body size.
    public static let tabStripHeight = LayoutMetricSetting(name: "tabStripHeight", range: 22...44, compact: 28, comfortable: 36)
    public static let tabFontSize = LayoutMetricSetting(name: "tabFontSize", range: 10...18, compact: 12, comfortable: 13)
    public static let tabBar: [LayoutMetricSetting] = [tabStripHeight, tabFontSize]

    public static let all: [LayoutMetricSetting] = [sidebarWidth, columnGap, dividerThickness, dividerHitWidth, titlebarHeight] + tabBar + tabWidths

    private static func token(_ name: String, _ range: ClosedRange<Double>, _ width: (MotionTabStrip) -> CGFloat) -> LayoutMetricSetting {
        LayoutMetricSetting(name: name, range: range, compact: Double(width(MotionTabStrip(comfortable: false))),
                            comfortable: Double(width(MotionTabStrip(comfortable: true))))
    }

    /// The range of every metric the schema lists, the interface size included, by name.
    public static var ranges: [String: ClosedRange<Double>] {
        var ranges = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.range) })
        ranges[InterfaceSizeSetting().metricName] = InterfaceSizeSetting().range
        return ranges
    }
}
