/// `app.uiScale` in cmux.json: the live scale applied to cmux chrome and
/// first-party web pages. Terminal content keeps its own font size.
public struct UIScaleSetting: Sendable {
    /// The cmux.json key path.
    public static let configPath = ["app", "uiScale"]
    /// The default scale, expressed as a multiplier (1 is 100%).
    public static let fallback = 1.0
    /// Supported display scale, from 85% through 150%.
    public static let range: ClosedRange<Double> = 0.85...1.5
    /// The increment used by the View menu and keyboard shortcuts.
    public static let step = 0.05
}
