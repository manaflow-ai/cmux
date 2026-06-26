import CmuxSettings
import Foundation

// App-side presentation for the shared `CmuxSettings.BrowserThemeMode` value.
// `displayName` resolves through `String(localized:)`, which must bind to the
// app bundle so non-English (Japanese) translations load; the settings package
// has no access to these catalog keys. Icon and identity are UI concerns kept
// here too, leaving the package type a pure `Sendable` value.
extension BrowserThemeMode: @retroactive Identifiable {
    /// Stable identity for SwiftUI lists, mirroring the raw value.
    var id: String { rawValue }

    /// Localized title shown in the browser theme picker.
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

    /// SF Symbol representing the theme mode in the browser toolbar.
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
