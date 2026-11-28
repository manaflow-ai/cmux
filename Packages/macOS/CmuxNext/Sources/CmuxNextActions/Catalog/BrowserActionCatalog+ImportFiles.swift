// Import from Another Browser… (cx-d0d.65): the files another browser exports.

nonisolated extension BrowserActionCatalog {
    static func importFilesDescriptors() -> [ActionDescriptor] {
        // The browser's export steps, then one picker for its passwords CSV and bookmarks HTML.
        // Person-only like the CSV import: an agent cannot put the picker in front of the person.
        var importFiles = ActionDescriptor(
            id: "browser.importFromFiles",
            title: String(localized: "action.browser.importFromFiles", defaultValue: "Import from Another Browser…", bundle: .module),
            keywords: ["browser", "import", "export", "passwords", "bookmarks", "csv", "html", "chrome", "edge", "brave",
                       "firefox", "safari"],
            category: .browser, symbol: "square.and.arrow.down", surfaces: [.palette, .menu], mainMenu: .file
        )
        importFiles.isPersonOnly = true
        return [importFiles]
    }
}
