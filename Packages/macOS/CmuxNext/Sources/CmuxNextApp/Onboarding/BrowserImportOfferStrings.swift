import Foundation

/// The browser-data import offer's strings (table `BrowserImportOffer`).
nonisolated enum BrowserImportOfferStrings {
    /// `browser`: the detected browser's name ("Google Chrome").
    static func title(browser: String) -> String {
        String(format: String(localized: "browserImportOffer.title", defaultValue: "Import bookmarks, history and passwords from %@",
                              table: "BrowserImportOffer", bundle: .module), browser)
    }
    static var detail: String {
        String(localized: "browserImportOffer.detail", defaultValue: "Nothing leaves this Mac.", table: "BrowserImportOffer", bundle: .module)
    }
    static var importData: String {
        String(localized: "browserImportOffer.import", defaultValue: "Import…", table: "BrowserImportOffer", bundle: .module)
    }
    static var notNow: String {
        String(localized: "browserImportOffer.notNow", defaultValue: "Not Now", table: "BrowserImportOffer", bundle: .module)
    }
}
