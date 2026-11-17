import Foundation

/// Surface tab bar layout from `surfaceTabBar.widthMode`, `.maxTabWidth` and
/// `.height` in cmux.json, read from the managed `UserDefaults` keys the
/// settings file store writes.
///
/// Readers fall back to the defaults when a key is missing or holds a value
/// of the wrong type, and clamp numbers to the supported ranges.
public struct SurfaceTabBarLayoutSettings {
    /// How surface tabs share the width of a pane's tab bar.
    public enum WidthMode: String, Sendable, CaseIterable {
        /// Tabs keep their width up to ``SurfaceTabBarLayoutSettings/maxTabWidth`` and scroll on overflow.
        case fixed
        /// Tabs stretch to share the pane's tab bar; they still scroll on overflow.
        case fill
    }

    /// The dotted cmux.json path for the width mode.
    public static let widthModePath = "surfaceTabBar.widthMode"
    /// The dotted cmux.json path for the maximum tab width.
    public static let maxTabWidthPath = "surfaceTabBar.maxTabWidth"
    /// The dotted cmux.json path for the tab bar height.
    public static let heightPath = "surfaceTabBar.height"

    /// The managed `UserDefaults` key that stores the width mode.
    public static let widthModeKey = "cmux.settings.surfaceTabBarWidthMode"
    /// The managed `UserDefaults` key that stores the maximum tab width.
    public static let maxTabWidthKey = "cmux.settings.surfaceTabBarMaxTabWidth"
    /// The managed `UserDefaults` key that stores the tab bar height.
    public static let heightKey = "cmux.settings.surfaceTabBarHeight"

    /// The width mode used when none is configured.
    public static let defaultWidthMode = WidthMode.fixed
    /// Bonsplit's built-in maximum, which cmux used before this setting existed.
    public static let defaultMaxTabWidth: CGFloat = 220
    /// The accepted maximum tab width, in points.
    public static let maxTabWidthRange: ClosedRange<CGFloat> = 100...600
    /// Matches the app's shared chrome bar height, so the tab bar lines up
    /// with the titlebar by default.
    public static let defaultHeight: CGFloat = 28
    /// The accepted tab bar height, in points.
    public static let heightRange: ClosedRange<CGFloat> = 24...48

    /// Every managed `UserDefaults` key this setting owns.
    public static let allKeys = [widthModeKey, maxTabWidthKey, heightKey]
    /// Every cmux.json path this setting owns.
    public static let allPaths = [widthModePath, maxTabWidthPath, heightPath]

    /// The defaults the readers consult.
    public let defaults: UserDefaults

    /// Creates a reader over the given defaults.
    ///
    /// - Parameter defaults: The store holding the managed keys.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The configured width mode, or ``defaultWidthMode`` when unset or unknown.
    public var widthMode: WidthMode {
        defaults.string(forKey: Self.widthModeKey).flatMap(WidthMode.init(rawValue:)) ?? Self.defaultWidthMode
    }

    /// The configured maximum tab width clamped to ``maxTabWidthRange``,
    /// or ``defaultMaxTabWidth`` when unset or not a finite number.
    public var maxTabWidth: CGFloat {
        Self.clamped(defaults.object(forKey: Self.maxTabWidthKey), to: Self.maxTabWidthRange) ?? Self.defaultMaxTabWidth
    }

    /// The configured tab bar height clamped to ``heightRange``,
    /// or ``defaultHeight`` when unset or not a finite number.
    public var height: CGFloat {
        Self.clamped(defaults.object(forKey: Self.heightKey), to: Self.heightRange) ?? Self.defaultHeight
    }

    private static func clamped(_ rawValue: Any?, to range: ClosedRange<CGFloat>) -> CGFloat? {
        guard let number = rawValue as? NSNumber, number.doubleValue.isFinite else { return nil }
        return min(max(CGFloat(number.doubleValue), range.lowerBound), range.upperBound)
    }
}
