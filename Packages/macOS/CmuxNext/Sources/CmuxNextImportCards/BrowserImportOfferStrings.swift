import CmuxNextCompat
import Foundation

/// The browser-data import offer's strings (table `BrowserImportOffer`).
public nonisolated struct BrowserImportOfferStrings {
    public nonisolated init() {}
    /// The bundle that holds `Resources/BrowserImportOffer.xcstrings` (this module's), for tests.
    static var bundle: Bundle { .module.inAppLanguage }
    /// `browser`: the detected browser's name ("Google Chrome").
    public static func title(browser: String) -> String {
        String(format: String(localized: "browserImportOffer.cookies.title", defaultValue: "Import sign-ins from %@",
                              table: "BrowserImportOffer", bundle: .module.inAppLanguage), browser)
    }
    /// Opens the browser sign-in import flow.
    public static var importData: String {
        String(localized: "browserImportOffer.import", defaultValue: "Import…", table: "BrowserImportOffer", bundle: .module.inAppLanguage)
    }
    /// Why an import action does not run while `browser.import.enabled` is off.
    public static var turnedOff: String {
        String(localized: "browserImportOffer.turnedOff", defaultValue: "Import from Browser is turned off in Settings > Browser.",
               table: "BrowserImportOffer", bundle: .module.inAppLanguage)
    }
    /// Permanently dismisses the offer, naming the detected browser.
    public static func never(browser: String) -> String {
        String(format: String(localized: "browserImportOffer.neverForBrowser", defaultValue: "Never for %@",
                              table: "BrowserImportOffer", bundle: .module.inAppLanguage), browser)
    }
    /// `browser`: the name of the browser whose cookies could no longer be read.
    public static func syncStopped(_ browser: String) -> String { String(format: String(localized: "browserImportOffer.syncStopped", defaultValue: "Stopped syncing cookies with %@: cmux could not read them. Import again.", table: "BrowserImportOffer", bundle: .module.inAppLanguage), browser) }
    /// Defers the offer for 30 days (``BrowserImportOfferState/notNowInterval``).
    public static var notNow: String {
        String(localized: "browserImportOffer.notNow", defaultValue: "Not now", table: "BrowserImportOffer", bundle: .module.inAppLanguage)
    }
}
