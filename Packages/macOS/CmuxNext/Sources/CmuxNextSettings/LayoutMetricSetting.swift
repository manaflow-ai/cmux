/// The `appearance.metrics.<name>` keys the schema lists besides the interface size (which has its
/// own `InterfaceSizeSetting`): sizes in points whose default is the density's. cmux-next and
/// cmux-browser both read them. Each `range` equals `DesignSettings.allowedRange` and each default
/// equals its `MetricTunables` preset (a test keeps them equal; this module reads no main-actor
/// state).
public nonisolated struct LayoutMetricSetting: Sendable, Hashable {
    /// The `MetricKey` raw value.
    public let name: String
    public let range: ClosedRange<Double>
    public let compact: Double
    public let comfortable: Double

    public var configPath: [String] { ["appearance", "metrics", name] }

    public static let sidebarWidth = LayoutMetricSetting(name: "sidebarWidth", range: 160...420, compact: 208, comfortable: 240)
    public static let columnGap = LayoutMetricSetting(name: "columnGap", range: 0...24, compact: 6, comfortable: 8)
    public static let titlebarHeight = LayoutMetricSetting(name: "titlebarHeight", range: 24...56, compact: 32, comfortable: 40)

    public static let all: [LayoutMetricSetting] = [sidebarWidth, columnGap, titlebarHeight]

    /// The range of every metric the schema lists, the interface size included, by name.
    public static var ranges: [String: ClosedRange<Double>] {
        var ranges = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.range) })
        ranges[InterfaceSizeSetting().metricName] = InterfaceSizeSetting().range
        return ranges
    }
}
