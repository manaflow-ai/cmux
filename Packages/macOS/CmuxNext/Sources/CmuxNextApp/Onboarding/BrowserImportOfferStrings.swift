import Foundation

/// The browser-data import offer's strings (table `BrowserImportOffer`).
nonisolated enum BrowserImportOfferStrings {
    /// The bundle that holds `Resources/BrowserImportOffer.xcstrings` (this module's), for tests.
    static var bundle: Bundle { .module }
    /// `browser`: the detected browser's name ("Google Chrome").
    static func title(browser: String) -> String {
        String(format: String(localized: "browserImportOffer.cookies.title", defaultValue: "Import cookies from %@",
                              table: "BrowserImportOffer", bundle: .module), browser)
    }
    static var detail: String { String(localized: "browserImportOffer.cookies.detail", defaultValue: "Stay signed in to your sites. Nothing leaves this Mac.", table: "BrowserImportOffer", bundle: .module) }
    static var importData: String {
        String(localized: "browserImportOffer.import", defaultValue: "Import…", table: "BrowserImportOffer", bundle: .module)
    }
    /// Why an import action does not run while `browser.import.enabled` is off.
    static var turnedOff: String {
        String(localized: "browserImportOffer.turnedOff", defaultValue: "Import from Browser is turned off in Settings > Browser.",
               table: "BrowserImportOffer", bundle: .module)
    }
    static var dontShowAgain: String { String(localized: "browserImportOffer.dontShowAgain", defaultValue: "Don't Show Again", table: "BrowserImportOffer", bundle: .module) }
    static var notNow: String {
        String(localized: "browserImportOffer.notNow", defaultValue: "Not Now", table: "BrowserImportOffer", bundle: .module)
    }
}
