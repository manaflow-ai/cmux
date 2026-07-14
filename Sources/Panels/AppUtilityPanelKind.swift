import Foundation

enum AppUtilityPanelKind: String, Equatable, Sendable {
    case settings
    case mobilePairing

    var displayTitle: String {
        switch self {
        case .settings:
            return String(localized: "settings.title", defaultValue: "Settings")
        case .mobilePairing:
            return String(localized: "mobile.pairing.window.title", defaultValue: "Pair iPhone")
        }
    }

    var displayIcon: String {
        switch self {
        case .settings: return "gearshape"
        case .mobilePairing: return "iphone"
        }
    }
}
