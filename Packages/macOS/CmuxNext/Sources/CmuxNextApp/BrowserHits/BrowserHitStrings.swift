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

    /// The media hub with no tab playing (BrowserMediaMenu).
    static var mediaNothingPlaying: String { t("browserHits.media.nothingPlaying", "Nothing Playing") }

    // The toolbar's Downloads menu (BrowserDownloadsMenu).
    static var downloadsEmpty: String { t("browserHits.downloads.empty", "No Downloads") }
    static var downloadsClear: String { t("browserHits.downloads.clear", "Clear Finished Downloads") }
    static var downloadOpen: String { t("browserHits.downloads.open", "Open") }
    static var downloadShowInFinder: String { t("browserHits.downloads.showInFinder", "Show in Finder") }
    static var downloadPause: String { t("browserHits.downloads.pause", "Pause") }
    static var downloadResume: String { t("browserHits.downloads.resume", "Resume") }
    static var downloadCancel: String { t("browserHits.downloads.cancel", "Cancel Download") }
    static var downloadCopyLink: String { t("browserHits.downloads.copyLink", "Copy Download Link") }
    static var downloadPaused: String { t("browserHits.downloads.paused", "Paused") }
    static var downloadFailedShort: String { t("browserHits.downloads.failed", "Failed") }
    static var downloadCancelled: String { t("browserHits.downloads.cancelled", "Cancelled") }
    static var downloadBlockedShort: String { t("browserHits.downloads.blocked", "Blocked") }

    /// The blocked-download notice's button: the site's Site settings.
    static var siteSettings: String { t("browserHits.download.siteSettings", "Site Settings…") }

    static func downloadFailed(_ name: String) -> String {
        String(format: t("browserHits.download.failed", "Could not download “%@”"), name)
    }

    static var urlRequired: String { t("browserHits.error.url", "This action needs a web address (url).") }
    static var textRequired: String { t("browserHits.error.text", "This action needs text.") }
    static var imageCopyFailed: String { t("browserHits.error.image", "The image could not be copied.") }
    static var noPage: String { t("browserHits.error.noPage", "No browser page is open here.") }
}
