import CmuxSettings
import Foundation

/// App-side presentation for ``BrowserThemeMode``.
///
/// `displayName` stays in the app target on purpose: its `String(localized:)`
/// keys (`theme.system`/`theme.light`/`theme.dark`) live in the app bundle's
/// catalog, so resolving them here keeps the Japanese translations. Moving them
/// into a package would rebind the lookup to that package's bundle and drop the
/// localization. `iconName` is colocated with it as the picker's view metadata.
extension BrowserThemeMode {
    /// Localized label shown in the theme picker.
    var displayName: String {
        switch self {
        case .system:
            return String(localized: "theme.system", defaultValue: "System")
        case .light:
            return String(localized: "theme.light", defaultValue: "Light")
        case .dark:
            return String(localized: "theme.dark", defaultValue: "Dark")
        }
    }

    /// SF Symbol name representing the mode in the theme picker.
    var iconName: String {
        switch self {
        case .system:
            return "circle.lefthalf.filled"
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        }
    }
}
