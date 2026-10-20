import Foundation

/// The shared file menu's text (table `Files`, 21 languages).
nonisolated enum FileActionStrings {
    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "Files", bundle: .module)
    }

    static var openInRightPane: String { t("files.menu.openInRightPane", "Open in Right Pane") }
    static var openWith: String { t("files.menu.openWith", "Open With") }
    static var other: String { t("files.menu.openWith.other", "Other…") }
    static var revealInFiles: String { t("files.menu.revealInFiles", "Reveal in cmux Files") }
    static var share: String { t("files.menu.share", "Share…") }
    static var searchThisFolder: String { t("files.search.thisFolder", "Search This Folder") }
    static var searchIndexing: String { t("files.search.indexing", "Indexing…") }

    /// An Open With row for the default app: "Safari (default)".
    static func defaultApp(_ name: String) -> String {
        String(format: t("files.menu.openWith.default", "%@ (default)"), name)
    }

    /// Other…'s panel message: "Choose an app to open “index.html”."
    static func chooseApp(_ name: String) -> String {
        String(format: t("files.menu.openWith.choose", "Choose an app to open “%@”."), name)
    }

    /// The search status line: "12 results in 100,000 items".
    static func searchResults(_ count: Int, _ total: Int) -> String {
        String(format: t("files.search.results", "%1$lld results in %2$lld items"), count, total)
    }
}
