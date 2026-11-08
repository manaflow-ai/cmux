// Edit Source and Open as Page (u18051, u18462): a page cmux renders (HTML, SVG, Markdown) and
// its source in the code editor are one action apart, whoever opened the file and however (an
// agent's `file.open`, `cmux open`, MCP, the Files pane, a terminal link, a drop). Edit Source on
// a tab showing the rendered page opens the source; Open as Page on a code editor tab showing such
// a file opens it rendered. Both are on the tab menu, the palette, the CLI and MCP.

nonisolated extension BrowserActionCatalog {
    static func editSourceDescriptors() -> [ActionDescriptor] {
        // The tab menu shows each only on a tab it applies to (TabSourceHandlers).
        [
            ActionDescriptor(
                id: "browser.editSource",
                title: String(localized: "action.browser.editSource", defaultValue: "Edit Source", bundle: .module),
                keywords: ["browser", "html", "svg", "markdown", "md", "source", "edit", "text", "code", "editor", "view source", "open as text", "file"],
                category: .browser, symbol: "chevron.left.forwardslash.chevron.right", surfaces: [.palette, .contextMenu],
                targets: [.tab], cliName: "browser edit-source"
            ),
            ActionDescriptor(
                id: "file.openAsPage",
                title: String(localized: "action.file.openAsPage", defaultValue: "Open as Page", bundle: .module),
                keywords: ["html", "svg", "markdown", "md", "render", "rendered", "preview", "page", "browser", "view", "file"],
                category: .browser, symbol: "doc.richtext", surfaces: [.palette, .contextMenu],
                targets: [.tab], cliName: "file open-as-page"
            ),
        ]
    }
}
