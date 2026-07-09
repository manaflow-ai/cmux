public import Foundation

public extension URL {
    /// Builds the deep link that opens cmux's row in the macOS notification
    /// settings pane. A non-empty bundle identifier (percent-encoded) targets
    /// that app's entry directly; an absent or blank identifier falls back to
    /// the general Notifications settings extension.
    static func notificationSettings(bundleIdentifier: String?) -> URL? {
        if let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty,
           let encodedBundleIdentifier = bundleIdentifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(encodedBundleIdentifier)"
            )
        }
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }
}
