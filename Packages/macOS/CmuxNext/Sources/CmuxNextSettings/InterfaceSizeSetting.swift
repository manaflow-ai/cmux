/// `appearance.metrics.chromeFontSize` in cmux.json: the interface size, the
/// body text size of tabs, the sidebar and other chrome in points. Absent
/// means the density's size (12 compact, 13 comfortable). The Settings
/// window and the palette's Increase, Decrease and Reset Interface Size
/// write it.
public enum InterfaceSizeSetting {
    /// The `MetricKey.chromeFontSize` raw value (a test keeps them equal).
    public static let metricName = "chromeFontSize"
    public static let configPath = ["appearance", "metrics", metricName]
    /// `DesignSettings.allowedRange(.chromeFontSize)` (a test keeps them equal).
    public static let range: ClosedRange<Double> = 10...16
}
