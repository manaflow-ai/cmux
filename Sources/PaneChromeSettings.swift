import Foundation

enum PaneChromeSettings {
    static let paneBorderColorKey = "paneBorderColor"
    static let activePaneBorderColorKey = "activePaneBorderColor"
    static let paneMinimumHeightKey = "paneMinimumHeight"
    static let minimumPaneMinimumHeight = 20.0
    static let maximumPaneMinimumHeight = 600.0
    static let defaultColorHex = ""
    static let activeBorderLineWidth = 2.0
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

    /// The configured minimum workspace pane height in points, or `nil` when
    /// unset (Bonsplit's default applies).
    static func paneMinimumHeight(defaults: UserDefaults = .standard) -> CGFloat? {
        guard let value = defaults.object(forKey: Self.paneMinimumHeightKey) as? Double else {
            return nil
        }
        return CGFloat(sanitizedPaneMinimumHeight(value))
    }

    static func sanitizedPaneMinimumHeight(_ value: Double) -> Double {
        min(max(value, minimumPaneMinimumHeight), maximumPaneMinimumHeight)
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: Self.didChangeNotification, object: nil)
    }

    private static func normalizedColorHex(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        return WorkspaceTabColorSettings.normalizedHex(rawValue)
    }
}
