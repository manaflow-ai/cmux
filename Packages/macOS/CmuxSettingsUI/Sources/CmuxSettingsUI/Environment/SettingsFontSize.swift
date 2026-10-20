import Foundation

/// A point size plus the range and default a font-size slider should use.
///
/// Font sizes (the left sidebar, the workspace tab bar) live in the Ghostty
/// config file rather than `UserDefaults`, so the package can't read them
/// through the catalog/``DefaultsValueModel`` path. Instead the host supplies
/// the current value together with its bounds via ``SettingsHostActions``, and
/// the settings UI renders a slider against this descriptor.
///
/// ```swift
/// let font = hostActions.sidebarFontSize()
/// Slider(value: $points, in: font.minimum...font.maximum, step: 0.5)
/// ```
public struct SettingsFontSize: Sendable, Equatable {
    /// The current effective size, in points.
    public var points: Double

    /// The smallest size the slider allows.
    public let minimum: Double

    /// The largest size the slider allows.
    public let maximum: Double

    /// The size restored by the row's Reset button.
    public let defaultValue: Double

    /// Creates a font-size descriptor.
    ///
    /// - Parameters:
    ///   - points: The current effective size, in points.
    ///   - minimum: The smallest size the slider allows.
    ///   - maximum: The largest size the slider allows.
    ///   - defaultValue: The size restored by the row's Reset button.
    public init(points: Double, minimum: Double, maximum: Double, defaultValue: Double) {
        self.points = points
        self.minimum = minimum
        self.maximum = maximum
        self.defaultValue = defaultValue
    }

    /// Whether ``points`` currently matches ``defaultValue`` (within a small
    /// tolerance), used to disable the Reset control.
    public var isDefault: Bool {
        abs(points - defaultValue) < 0.001
    }
}
