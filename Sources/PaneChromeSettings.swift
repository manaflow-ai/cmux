import Bonsplit
import Foundation

enum PaneChromeSettings {
    static let paneBorderColorKey = "paneBorderColor"
    static let activePaneBorderColorKey = "activePaneBorderColor"
    static let defaultColorHex = ""
    static let didChangeNotification = Notification.Name("cmux.paneChromeSettingsDidChange")

    static func paneBorderColorHex(defaults: UserDefaults = .standard) -> String? {
        normalizedColorHex(defaults.string(forKey: Self.paneBorderColorKey))
    }

    static func activePaneBorderColorHex(defaults: UserDefaults = .standard) -> String? {
        normalizedColorHex(defaults.string(forKey: Self.activePaneBorderColorKey))
    }

    static func resolvedPaneBorderHex(configuredHex: String?, fallback: String) -> String {
        normalizedColorHex(configuredHex) ?? fallback
    }

    static func paneBorderColorHexIsUnset(_ configuredHex: String?) -> Bool {
        normalizedColorHex(configuredHex) == nil
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: Self.didChangeNotification, object: nil)
    }

    private static func normalizedColorHex(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        return WorkspaceTabColorSettings.normalizedHex(rawValue)
    }
}

/// Surface tab bar layout from `surfaceTabBar.widthMode`, `.maxTabWidth` and
/// `.height` in cmux.json. Changes post ``PaneChromeSettings/didChangeNotification``,
/// which already makes every workspace and Dock reapply its Bonsplit appearance.
struct SurfaceTabBarLayoutSettings {
    enum WidthMode: String {
        /// Tabs keep their width up to ``SurfaceTabBarLayoutSettings/maxTabWidth`` and scroll on overflow.
        case fixed
        /// Tabs stretch to share the pane's tab bar; they still scroll on overflow.
        case fill

        var bonsplitTabWidthMode: BonsplitConfiguration.Appearance.TabWidthMode {
            switch self {
            case .fixed: .fixed
            case .fill: .fill
            }
        }
    }

    static let widthModePath = "surfaceTabBar.widthMode"
    static let maxTabWidthPath = "surfaceTabBar.maxTabWidth"
    static let heightPath = "surfaceTabBar.height"

    static let widthModeKey = "cmux.settings.surfaceTabBarWidthMode"
    static let maxTabWidthKey = "cmux.settings.surfaceTabBarMaxTabWidth"
    static let heightKey = "cmux.settings.surfaceTabBarHeight"

    static let defaultWidthMode = WidthMode.fixed
    /// Bonsplit's built-in maximum, which cmux used before this setting existed.
    static let defaultMaxTabWidth: CGFloat = 220
    static let maxTabWidthRange: ClosedRange<CGFloat> = 100...600
    /// Matches the titlebar, so the tab bar lines up with it by default.
    static let defaultHeight: CGFloat = WindowChromeMetrics.sharedChromeBarHeight
    static let heightRange: ClosedRange<CGFloat> = 24...48

    static let allKeys = [widthModeKey, maxTabWidthKey, heightKey]
    static let allPaths = [widthModePath, maxTabWidthPath, heightPath]

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var widthMode: WidthMode {
        defaults.string(forKey: Self.widthModeKey).flatMap(WidthMode.init(rawValue:)) ?? Self.defaultWidthMode
    }

    var maxTabWidth: CGFloat {
        clamped(defaults.object(forKey: Self.maxTabWidthKey), to: Self.maxTabWidthRange) ?? Self.defaultMaxTabWidth
    }

    var height: CGFloat {
        clamped(defaults.object(forKey: Self.heightKey), to: Self.heightRange) ?? Self.defaultHeight
    }

    private func clamped(_ rawValue: Any?, to range: ClosedRange<CGFloat>) -> CGFloat? {
        guard let number = rawValue as? NSNumber, number.doubleValue.isFinite else { return nil }
        return min(max(CGFloat(number.doubleValue), range.lowerBound), range.upperBound)
    }
}
