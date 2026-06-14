public import Foundation

/// Controls visibility of the DEBUG dev-build banner in the sidebar footer.
/// Pure value namespace reading from an injected `UserDefaults`.
// lint:allow namespace-type — pure stateless policy/value namespace lifted verbatim from ContentView; no natural receiver, modernization deferred.
public enum DevBuildBannerDebugSettings {
    /// Defaults key backing sidebar dev-build banner visibility.
    public static let sidebarBannerVisibleKey = "showSidebarDevBuildBanner"
    /// Default when the user has not stored a preference.
    public static let defaultShowSidebarBanner = true

    /// Whether the sidebar dev-build banner should be shown.
    public static func showSidebarBanner(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: sidebarBannerVisibleKey) != nil else {
            return defaultShowSidebarBanner
        }
        return defaults.bool(forKey: sidebarBannerVisibleKey)
    }
}
