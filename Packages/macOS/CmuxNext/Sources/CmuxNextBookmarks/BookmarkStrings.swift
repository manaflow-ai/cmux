import Foundation

/// Strings of the bookmark surfaces (Resources/Localizable.xcstrings).
public nonisolated enum BookmarkStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    public static var barTitle: String { t("root.bar", "Bookmarks Bar") }
    public static var otherBookmarks: String { t("root.other", "Other Bookmarks") }
    public static var pageTitle: String { t("page.title", "Bookmarks") }
    public static var searchPlaceholder: String { t("page.search", "Search bookmarks") }
    public static var noMatches: String { t("page.noMatches", "No matches") }
    public static var emptyFolder: String { t("folder.empty", "(empty)") }
    public static var moreBookmarks: String { t("bar.more", "More Bookmarks") }
    public static var barEmptyHint: String { t("bar.emptyHint", "Drag a link here or click the star to add bookmarks") }
    public static var added: String { t("bubble.added", "Bookmark Added") }
    public static var editTitle: String { t("bubble.edit", "Edit Bookmark") }
    public static var name: String { t("field.name", "Name") }
    public static var url: String { t("field.url", "URL") }
    public static var folder: String { t("field.folder", "Folder") }
    public static var more: String { t("bubble.more", "More…") }
    public static var remove: String { t("bubble.remove", "Remove") }
    public static var done: String { t("bubble.done", "Done") }
    public static var save: String { t("editor.save", "Save") }
    public static var cancel: String { t("editor.cancel", "Cancel") }
    public static var newFolder: String { t("folder.new", "New Folder") }
    public static var invalidURL: String { t("editor.invalidURL", "Enter a valid URL") }
    public static var addBookmark: String { t("verb.addBookmark", "Add Bookmark…") }
    public static var addFolder: String { t("verb.addFolder", "Add Folder…") }
    public static var importHTML: String { t("verb.import", "Import Bookmarks…") }
    public static var importFromBrowser: String { t("verb.importBrowser", "Import from Browser…") }
    public static var exportHTML: String { t("verb.export", "Export Bookmarks…") }
    public static var open: String { t("verb.open", "Open") }
    public static var openInNewTab: String { t("verb.openInNewTab", "Open in New Tab") }
    public static var openInBackgroundTab: String { t("verb.openInBackgroundTab", "Open in Background Tab") }
    public static var edit: String { t("verb.edit", "Edit…") }
    public static var rename: String { t("verb.rename", "Rename…") }
    public static var delete: String { t("verb.delete", "Delete") }
    public static var copyURL: String { t("verb.copyURL", "Copy URL") }
    public static var showInFolder: String { t("verb.showInFolder", "Show in Folder") }

    public static func openAll(_ count: Int) -> String {
        String(format: t("verb.openAll", "Open All (%lld)"), count)
    }
}
