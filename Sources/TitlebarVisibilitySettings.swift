import Foundation

enum ChromeControlsVisibilityMode: String, CaseIterable, Identifiable {
    case always
    case onHover

    var id: String { rawValue }
}

enum TitlebarControlsVisibilitySettings {
    static let modeKey = "titlebarControlsVisibilityMode"
    static let defaultMode: ChromeControlsVisibilityMode = .always

    static func mode(for rawValue: String?) -> ChromeControlsVisibilityMode {
        guard let rawValue, let mode = ChromeControlsVisibilityMode(rawValue: rawValue) else {
            return defaultMode
        }
        return mode
    }
}

enum PaneTabBarControlsVisibilitySettings {
    static let modeKey = "paneTabBarControlsVisibilityMode"
    static let defaultMode: ChromeControlsVisibilityMode = .always

    static func mode(for rawValue: String?) -> ChromeControlsVisibilityMode {
        guard let rawValue, let mode = ChromeControlsVisibilityMode(rawValue: rawValue) else {
            return defaultMode
        }
        return mode
    }
}

enum WorkspaceTitlebarSettings {
    static let showTitlebarKey = "workspaceTitlebarVisible"
    static let defaultShowTitlebar = true

    static func isVisible(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showTitlebarKey) == nil {
            return defaultShowTitlebar
        }
        return defaults.bool(forKey: showTitlebarKey)
    }
}
