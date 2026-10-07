import CmuxNextBookmarks
import Foundation

/// App strings for bookmarks (table Bookmarks.xcstrings).
enum BookmarkAppStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Bookmarks", bundle: .module)
    }

    static var cannotBookmark: String { t("bookmarks.refusal.cannotBookmark", "This page cannot be bookmarked") }
    static var notFound: String { t("bookmarks.refusal.notFound", "No bookmark matches that") }
    static var needsBookmark: String { t("bookmarks.refusal.needsBookmark", "Name a bookmark (id, URL or title)") }
    static var invalidURL: String { t("bookmarks.refusal.invalidURL", "That is not a valid URL") }
    static var notFolder: String { t("bookmarks.refusal.notFolder", "That is not a bookmark folder") }
    static var noBrowserTab: String { t("bookmarks.refusal.noBrowserTab", "Focus a browser tab first") }
    static var noTabs: String { t("bookmarks.refusal.noTabs", "This pane has no web pages to bookmark") }
    static var importEmpty: String { t("bookmarks.refusal.importEmpty", "The file has no bookmarks") }
    static var importPrompt: String { t("bookmarks.import.prompt", "Choose a bookmarks HTML file") }
    static var importedFolder: String { t("bookmarks.import.folder", "Imported") }
    static var exportFileName: String { t("bookmarks.export.fileName", "bookmarks.html") }
    static var allTabsFolder: String { t("bookmarks.allTabs.folder", "Saved Tabs") }
    static var openTitle: String { t("bookmarks.palette.title", "Open Bookmark") }
    static var openPlaceholder: String { t("bookmarks.palette.placeholder", "Search bookmarks…") }
    static var open: String { t("bookmarks.palette.open", "Open") }
    static var openInNewTab: String { t("bookmarks.palette.openInNewTab", "Open in New Tab") }
    static var copyURL: String { t("bookmarks.palette.copyURL", "Copy URL") }
    static var delete: String { t("bookmarks.palette.delete", "Delete") }
    static var showInManager: String { t("bookmarks.palette.showInManager", "Show in Bookmark Manager") }

    static func failure(_ error: any Error) -> String {
        switch error as? BookmarkError {
        case .notFound?: t("bookmarks.error.notFound", "That bookmark no longer exists")
        case .invalidParent?: notFolder
        case .cycle?: t("bookmarks.error.cycle", "A folder cannot move into itself")
        case .invalidURL?: invalidURL
        case .invalidKind?: t("bookmarks.error.invalidKind", "A folder has no URL")
        case .tooLarge?: t("bookmarks.error.tooLarge", "Too many bookmarks or too long a name")
        case .tooDeep?: t("bookmarks.error.tooDeep", "Folders cannot nest that deep")
        case nil: String(format: t("bookmarks.error.other", "Bookmark error: %@"), String(describing: error))
        }
    }
}
