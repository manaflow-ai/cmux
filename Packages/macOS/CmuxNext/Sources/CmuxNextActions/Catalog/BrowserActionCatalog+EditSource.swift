// Edit Source (u18051): a browser tab that renders a local web page (HTML, SVG) opens the file's
// source in the code editor, one click from the page, as Open as Text does from a file menu.

nonisolated extension BrowserActionCatalog {
    static func editSourceDescriptors() -> [ActionDescriptor] {
        // The tab menu shows it only on a browser tab showing a local HTML or SVG file.
        [ActionDescriptor(
            id: "browser.editSource",
            title: String(localized: "action.browser.editSource", defaultValue: "Edit Source", bundle: .module),
            keywords: ["browser", "html", "svg", "source", "edit", "text", "code", "editor", "view source", "file"],
            category: .browser, symbol: "chevron.left.forwardslash.chevron.right", surfaces: [.palette, .contextMenu],
            targets: [.tab], cliName: "browser edit-source"
        )]
    }
}
