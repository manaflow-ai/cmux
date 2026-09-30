import Foundation

enum PaneChromeSettings {
    static let paneBorderColorKey = "paneBorderColor"
    static let activePaneBorderColorKey = "activePaneBorderColor"
    static let focusMarkerStyleKey = "focusMarkerStyle"
    static let focusMarkerColorKey = "focusMarkerColor"
    static let focusMarkerThicknessKey = "focusMarkerThickness"
    static let focusMarkerIntensityKey = "focusMarkerIntensity"
    static let focusMarkerVisibilityKey = "focusMarkerVisibility"
    static let defaultColorHex = ""
    static let defaultFocusMarkerStyle = "edge"
    static let defaultFocusMarkerThickness = 2.0
    static let defaultFocusMarkerIntensity = 0.24
    static let defaultFocusMarkerVisibility = "persistent"
    static let didChangeNotification = Notification.Name("cmux.paneChromeSettingsDidChange")

    enum Style: String, CaseIterable, Identifiable {
        case edge
        case dimOthers = "dim-others"
        case glow
        case none
        var id: String { rawValue }
    }

    enum Visibility: String, CaseIterable, Identifiable {
        case persistent
        case onChange = "on-change"
        var id: String { rawValue }
    }

    static func paneBorderColorHex(defaults: UserDefaults = .standard) -> String? {
        normalizedColorHex(defaults.string(forKey: Self.paneBorderColorKey))
    }

    static func activePaneBorderColorHex(defaults: UserDefaults = .standard) -> String? {
        normalizedColorHex(defaults.string(forKey: Self.activePaneBorderColorKey))
    }

    static func focusMarkerStyle(defaults: UserDefaults = .standard) -> Style {
        Style(rawValue: defaults.string(forKey: focusMarkerStyleKey) ?? "") ?? .edge
    }

    static func focusMarkerColorHex(defaults: UserDefaults = .standard) -> String? {
        normalizedColorHex(defaults.string(forKey: focusMarkerColorKey))
    }

    static func focusMarkerThickness(defaults: UserDefaults = .standard) -> Double {
        let value = defaults.object(forKey: focusMarkerThicknessKey) as? Double ?? defaultFocusMarkerThickness
        return min(max(value, 1), 6)
    }

    static func focusMarkerIntensity(defaults: UserDefaults = .standard) -> Double {
        let value = defaults.object(forKey: focusMarkerIntensityKey) as? Double ?? defaultFocusMarkerIntensity
        return min(max(value, 0.05), 0.8)
    }

    static func focusMarkerVisibility(defaults: UserDefaults = .standard) -> Visibility {
        Visibility(rawValue: defaults.string(forKey: focusMarkerVisibilityKey) ?? "") ?? .persistent
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
