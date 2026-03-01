import Foundation

struct BrowserSettings {
    /// UserDefaults key controlling whether the WKWebView browser is enabled.
    /// When `false`, all browser creation paths (keyboard shortcut, socket API,
    /// session restore) are blocked.
    static let enabledKey = "browserEnabled"

    /// Returns `true` when the browser feature is enabled (the default).
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}
