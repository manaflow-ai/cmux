public import Foundation

/// Controls visibility of the DEBUG dev-build banner in the sidebar footer.
/// Reads from an injected `UserDefaults`.
public struct DevBuildBannerDebugSettings {
    /// Defaults key backing sidebar dev-build banner visibility.
    public static let sidebarBannerVisibleKey = "showSidebarDevBuildBanner"
    /// Default when the user has not stored a preference.
    public static let defaultShowSidebarBanner = true

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the sidebar dev-build banner should be shown.
    public var showSidebarBanner: Bool {
        guard defaults.object(forKey: Self.sidebarBannerVisibleKey) != nil else {
            return Self.defaultShowSidebarBanner
        }
        return defaults.bool(forKey: Self.sidebarBannerVisibleKey)
    }
}
