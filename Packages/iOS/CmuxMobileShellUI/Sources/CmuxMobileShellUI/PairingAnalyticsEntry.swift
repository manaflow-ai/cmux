/// The surface that opened the add-computer flow, used for pairing analytics.
enum PairingAnalyticsEntry: String, Equatable {
    case onboardingFallback = "onboarding_scanner"
    case settingsReplay = "settings_scanner"
}
