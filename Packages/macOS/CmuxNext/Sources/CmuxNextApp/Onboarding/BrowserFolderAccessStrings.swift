import Foundation

/// The open panel of a browser folder grant (table `BrowserImportOffer`).
nonisolated enum BrowserFolderAccessStrings {
    static var prompt: String {
        String(localized: "browserImport.access.prompt", defaultValue: "Allow Access", table: "BrowserImportOffer", bundle: .module)
    }
    /// `browser`: the browser's name ("Google Chrome").
    static func message(_ browser: String) -> String {
        String(format: String(localized: "browserImport.access.message",
                              defaultValue: "Select “Allow Access” to let cmux read your %@ data.",
                              table: "BrowserImportOffer", bundle: .module), browser)
    }
}
