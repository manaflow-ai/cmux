import Foundation

/// The Mobile Pairing page's native strings; the page's own text shares the
/// table (`MobilePairing.xcstrings`, `mobilePairing.page.` keys).
struct MobilePairingStrings {
    /// The tab title.
    static var pageTitle: String {
        String(localized: "mobilePairing.page.title", defaultValue: "Pair your iPhone", table: "MobilePairing", bundle: .module)
    }

    /// Phone access cannot be written before Settings has loaded.
    static var settingsNotLoaded: String {
        String(localized: "mobilePairing.settingsNotLoaded", defaultValue: "Settings are still loading. Try again in a moment.",
               table: "MobilePairing", bundle: .module)
    }
}
