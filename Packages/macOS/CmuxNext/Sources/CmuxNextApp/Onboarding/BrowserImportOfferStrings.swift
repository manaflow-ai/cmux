import Foundation

/// The browser-data import offer's strings (table `BrowserImportOffer`).
nonisolated enum BrowserImportOfferStrings {
    /// The bundle that holds `Resources/BrowserImportOffer.xcstrings` (this module's), for tests.
    static var bundle: Bundle { .module.inAppLanguage }
    /// `browser`: the detected browser's name ("Google Chrome").
    static func title(browser: String) -> String {
        String(format: String(localized: "browserImportOffer.cookies.title", defaultValue: "Import sign-ins from %@",
                              table: "BrowserImportOffer", bundle: .module.inAppLanguage), browser)
    }
    static var importData: String {
        String(localized: "browserImportOffer.import", defaultValue: "Import…", table: "BrowserImportOffer", bundle: .module.inAppLanguage)
    }
    /// Why an import action does not run while `browser.import.enabled` is off.
    static var turnedOff: String {
        String(localized: "browserImportOffer.turnedOff", defaultValue: "Import from Browser is turned off in Settings > Browser.",
               table: "BrowserImportOffer", bundle: .module.inAppLanguage)
    }
    static var dontShowAgain: String { String(localized: "browserImportOffer.dontShowAgain", defaultValue: "Don't Show Again", table: "BrowserImportOffer", bundle: .module.inAppLanguage) }
    /// `browser`: the name of the browser whose cookies could no longer be read.
    static func syncStopped(_ browser: String) -> String { String(format: String(localized: "browserImportOffer.syncStopped", defaultValue: "Stopped keeping cookies in sync with %@: cmux could not read them. Import again to turn it back on.", table: "BrowserImportOffer", bundle: .module.inAppLanguage), browser) }
    static var notNow: String {
        String(localized: "browserImportOffer.notNow", defaultValue: "Not Now", table: "BrowserImportOffer", bundle: .module.inAppLanguage)
    }
}
