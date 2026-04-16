import Foundation

/// Developer-only toggle that swaps the editor panel view between the Monaco
/// (`WKWebView`) backend (default) and the native `NSTextView` backend.
///
/// This is intentionally not a user-facing setting; it lives under the Debug
/// menu and reads a plain `UserDefaults` key. Changes take effect the next
/// time an editor tab is mounted — existing tabs keep their current backend
/// until reopened.
enum EditorBackendSettings {
    static let defaultsKey = "editor.backend.useMonaco"
    static let didChangeNotification = Notification.Name("cmux.editorBackendSettingsDidChange")
    static let defaultUseMonaco = true

    static func useMonaco(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: defaultsKey) == nil {
            return defaultUseMonaco
        }
        return defaults.bool(forKey: defaultsKey)
    }

    static func setUseMonaco(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
