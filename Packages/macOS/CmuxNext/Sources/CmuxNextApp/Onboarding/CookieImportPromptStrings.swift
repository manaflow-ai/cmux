import Foundation

/// The cookie import card's strings (table `CookieImportPrompt`).
nonisolated enum CookieImportPromptStrings {
    static var title: String {
        String(localized: "cookieImport.prompt.title", defaultValue: "Stay signed in to your sites", table: "CookieImportPrompt", bundle: .module)
    }
    static var detail: String {
        String(localized: "cookieImport.prompt.detail",
               defaultValue: "Import cookies from your other browsers. Only cookies come over, and nothing leaves this Mac.",
               table: "CookieImportPrompt", bundle: .module)
    }
    static var importCookies: String {
        String(localized: "cookieImport.prompt.import", defaultValue: "Import Cookies…", table: "CookieImportPrompt", bundle: .module)
    }
    static var notNow: String {
        String(localized: "cookieImport.prompt.notNow", defaultValue: "Not Now", table: "CookieImportPrompt", bundle: .module)
    }
    static var never: String {
        String(localized: "cookieImport.prompt.never", defaultValue: "Don’t Show Again", table: "CookieImportPrompt", bundle: .module)
    }
}
