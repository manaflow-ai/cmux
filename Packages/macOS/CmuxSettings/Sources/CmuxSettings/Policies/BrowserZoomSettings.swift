import Foundation

/// Shared policy for embedded-browser page magnification.
///
/// The configured value is a zoom factor (`1.0` is 100%). It is applied to each
/// newly created webview and by the Actual Size/reset action; user gestures
/// (⌘+/⌘–) then own an individual page's zoom. Keeping normalization here means
/// UserDefaults, cmux.json, the settings UI, and runtime callers agree on the
/// same finite range.
public struct BrowserZoomSettings: Sendable {
    /// Creates a stateless browser zoom policy value.
    public init() {}

    /// UserDefaults key used by the `browser.defaultZoomLevel` setting.
    public static let userDefaultsKey = "browserDefaultZoomLevel"

    /// Default page zoom factor (100%).
    public static let defaultLevel: Double = 1.0

    /// Smallest supported page zoom factor (25%).
    public static let minimumLevel: Double = 0.25

    /// Largest supported page zoom factor (500%).
    public static let maximumLevel: Double = 5.0

    /// Step used by the settings UI and keyboard zoom actions.
    public static let step: Double = 0.1

    /// Returns a finite value bounded to the supported page-zoom range.
    /// Non-finite or absent values use the 100% default.
    public func normalized(_ rawValue: Double?) -> Double {
        guard let rawValue, rawValue.isFinite else { return Self.defaultLevel }
        return min(max(rawValue, Self.minimumLevel), Self.maximumLevel)
    }

    /// Reads and normalizes the configured default from a UserDefaults suite.
    ///
    /// - Parameter defaults: The settings suite that owns the browser default.
    /// - Returns: The configured finite zoom factor, clamped to the supported range.
    public func current(defaults: UserDefaults) -> Double {
        normalized(Double.decodeFromUserDefaults(defaults.object(forKey: Self.userDefaultsKey)))
    }
}
