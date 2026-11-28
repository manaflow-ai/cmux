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
    static var folderHasNoLink: String { t("bookmarks.refusal.folderHasNoLink", "A folder has no link to copy") }
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

    // Import from another browser (BOOKMARKS-IMPORT-EVERY-BROWSER I4).
    static var importTitle: String { t("bookmarks.importBrowser.title", "Import Bookmarks") }
    static var importLead: String {
        t("bookmarks.importBrowser.lead", "Choose the browser profiles to import. Each one goes into its own folder on the Bookmarks Bar.")
    }
    static var importNoBrowser: String {
        t("bookmarks.importBrowser.none", "No browser with bookmarks was found on this Mac. You can import an exported HTML file.")
    }
    static var importChooseFile: String { t("bookmarks.importBrowser.chooseFile", "Choose HTML File…") }
    static var importOpenPrivacy: String { t("bookmarks.importBrowser.openPrivacy", "Open Privacy Settings") }
    static var importConfirm: String { t("bookmarks.importBrowser.confirm", "Import") }

    static func importNeedsFullDiskAccess(_ browser: String) -> String {
        String(format: t("bookmarks.importBrowser.fullDiskAccess",
                         "%1$@: cmux needs Full Disk Access to read its bookmarks. Allow it in System Settings, or export them from %1$@ as an HTML file."),
               browser)
    }

    static func importExportFirst(_ browser: String) -> String {
        String(format: t("bookmarks.importBrowser.exportFirst",
                         "%1$@ keeps bookmarks in its own format. Export them from %1$@ as an HTML file, then choose the file."), browser)
    }

    static func importedFrom(_ browser: String) -> String {
        String(format: t("bookmarks.importBrowser.folderSingle", "Imported from %@"), browser)
    }

    static func importedFrom(_ browser: String, profile: String) -> String {
        String(format: t("bookmarks.importBrowser.folder", "Imported from %1$@ (%2$@)"), browser, profile)
    }

    static func importSummary(added: Int, duplicates: Int, sources: String) -> String {
        String(format: t("bookmarks.importBrowser.summary", "Imported from %1$@. Bookmarks added: %2$lld. Duplicates skipped: %3$lld."),
               sources, Int64(added), Int64(duplicates))
    }

    static func importFailed(_ sources: String) -> String {
        String(format: t("bookmarks.importBrowser.failed", "Could not read: %@."), sources)
    }

    static func importUnknownSource(_ query: String) -> String {
        String(format: t("bookmarks.importBrowser.unknown", "No browser profile with bookmarks matches “%@”."), query)
    }

    static func failure(_ error: any Error) -> String {
        switch error as? BookmarkError {
        case .notFound?: t("bookmarks.error.notFound", "That bookmark no longer exists")
        case .invalidParent?: notFolder
        case .cycle?: t("bookmarks.error.cycle", "A folder cannot move into itself")
        case .invalidURL?: invalidURL
        case .invalidKind?: t("bookmarks.error.invalidKind", "A folder has no URL")
        case .tooLarge?: t("bookmarks.error.tooLarge", "Too many bookmarks or too long a name")
        case .tooDeep?: t("bookmarks.error.tooDeep", "Folders cannot nest that deep")
        case nil: String(format: t("bookmarks.error.other", "Bookmark error: %@"), RefusalStrings.describe(error))
        }
    }
}
