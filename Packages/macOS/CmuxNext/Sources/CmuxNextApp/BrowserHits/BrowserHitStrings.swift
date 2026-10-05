import Foundation

/// Strings of the page menu's link, image and selection rows (BrowserHits.xcstrings).
enum BrowserHitStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "BrowserHits", bundle: .module)
    }

    /// Search Google for “…” (the omnibar's engine).
    static func search(engine: String, _ snippet: String) -> String {
        String(format: t("browserHits.menu.search", "Search %1$@ for “%2$@”"), engine, snippet)
    }

    /// Look Up “…”.
    static func lookUp(_ snippet: String) -> String {
        String(format: t("browserHits.menu.lookUp", "Look Up “%@”"), snippet)
    }

    /// The notice over a tab when its download ends (`BrowserDownloadList`).
    static func downloadFinished(_ name: String) -> String {
        String(format: t("browserHits.download.finished", "Downloaded “%@”"), name)
    }

    static func downloadBlocked(_ name: String) -> String {
        String(format: t("browserHits.download.blocked", "Blocked download of “%@”"), name)
    }

    static func downloadFailed(_ name: String) -> String {
        String(format: t("browserHits.download.failed", "Could not download “%@”"), name)
    }

    static var urlRequired: String { t("browserHits.error.url", "This action needs a web address (url).") }
    static var textRequired: String { t("browserHits.error.text", "This action needs text.") }
    static var imageCopyFailed: String { t("browserHits.error.image", "The image could not be copied.") }
    static var noPage: String { t("browserHits.error.noPage", "No browser page is open here.") }
}
