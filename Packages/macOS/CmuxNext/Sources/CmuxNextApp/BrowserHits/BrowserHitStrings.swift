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

    static var urlRequired: String { t("browserHits.error.url", "This action needs a web address (url).") }
    static var textRequired: String { t("browserHits.error.text", "This action needs text.") }
    static var chromiumSave: String { t("browserHits.error.chromiumSave", "Chromium tabs save from the page's right-click menu for now.") }
    static var imageCopyFailed: String { t("browserHits.error.image", "The image could not be copied.") }
    static var noPage: String { t("browserHits.error.noPage", "No browser page is open here.") }
}
