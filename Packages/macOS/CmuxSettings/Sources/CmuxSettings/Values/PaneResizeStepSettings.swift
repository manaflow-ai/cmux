import Foundation

/// Bounds and persistence metadata for keyboard-driven pane resizing.
public struct PaneResizeStepSettings {
    private let defaults: UserDefaults

    /// Creates a resize-step reader using the supplied preferences store.
    ///
    /// - Parameter defaults: The app's preferences or an isolated test suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The UserDefaults key shared with the legacy app settings bridge.
    public static let key = "paneResizeStepPixels"
    /// The default divider movement, in points, for each key event.
    public static let defaultPixels = 20
    /// The smallest accepted divider movement, in points.
    public static let minimumPixels = 1
    /// The largest accepted divider movement, in points.
    public static let maximumPixels = 200

    /// Clamps a persisted or UI-provided value to the supported range.
    ///
    /// - Parameter pixels: The requested divider movement.
    /// - Returns: A value in the inclusive 1–200 range.
    public static func normalizedPixels(_ pixels: Int) -> Int {
        min(max(pixels, minimumPixels), maximumPixels)
    }

    /// Reads and normalizes the current step from the supplied defaults store.
    ///
    /// - Returns: The current movement, using 20 when no integer is stored.
    public func currentPixels() -> UInt16 {
        let rawValue = defaults.object(forKey: Self.key) as? Int ?? Self.defaultPixels
        return UInt16(Self.normalizedPixels(rawValue))
    }
}
