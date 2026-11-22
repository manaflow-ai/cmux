import Foundation

/// The Mobile Pairing page's native strings; the page's own text shares the
/// table (`MobilePairing.xcstrings`, `mobilePairing.page.` keys).
struct MobilePairingStrings {
    /// The tab title.
    static var pageTitle: String {
        String(localized: "mobilePairing.page.title", defaultValue: "Pair your iPhone", table: "MobilePairing", bundle: .module.inAppLanguage)
    }

    /// Phone access cannot be written: Settings did not load within the wait.
    static var settingsNotLoaded: String {
        String(localized: "mobilePairing.settingsNotLoaded", defaultValue: "Settings did not load, so phone access did not change.",
               table: "MobilePairing", bundle: .module.inAppLanguage)
    }
}
