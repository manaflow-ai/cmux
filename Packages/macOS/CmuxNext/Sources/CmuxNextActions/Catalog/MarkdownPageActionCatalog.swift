// The markdown page's own actions (diff-host S6) beyond its zoom rows in
// BrowserActionCatalog. Each sends a page command (`MarkdownPageCommand`
// in CmuxNextPages) to the focused cmux.markdown page. Titles live in
// ActionCatalog.xcstrings.

nonisolated enum MarkdownPageActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "markdownSave",
                title: String(localized: "action.markdownSave", defaultValue: "Markdown: Save", bundle: .module),
                keywords: ["markdown", "save", "file"], defaultShortcut: Shortcut("s", modifiers: [.command]),
                category: .browser, symbol: "square.and.arrow.down", surfaces: [.palette, .keyboard],
                requires: [.markdownFocused], targets: [.pane], cliName: "browser markdown-save"
            ),
            ActionDescriptor(
                id: "markdownLink",
                title: String(localized: "action.markdownLink", defaultValue: "Markdown: Insert Link", bundle: .module),
                // Decision K1: Cmd-K is Clear Screen and Scrollback only; Cmd-Shift-K inserts a link.
                keywords: ["markdown", "link", "url"], defaultShortcut: Shortcut("k", modifiers: [.command, .shift]),
                category: .browser, symbol: "link", surfaces: [.palette, .keyboard],
                requires: [.markdownFocused], targets: [.pane], cliName: "browser markdown-link"
            ),
            ActionDescriptor(
                id: "markdownBack",
                title: String(localized: "action.markdownBack", defaultValue: "Markdown: Back", bundle: .module),
                keywords: ["markdown", "back", "history"], defaultShortcut: Shortcut("[", modifiers: [.command]),
                category: .browser, symbol: "chevron.backward", surfaces: [.palette, .keyboard],
                requires: [.markdownFocused], targets: [.pane], cliName: "browser markdown-back"
            ),
            ActionDescriptor(
                id: "markdownForward",
                title: String(localized: "action.markdownForward", defaultValue: "Markdown: Forward", bundle: .module),
                keywords: ["markdown", "forward", "history"], defaultShortcut: Shortcut("]", modifiers: [.command]),
                category: .browser, symbol: "chevron.forward", surfaces: [.palette, .keyboard],
                requires: [.markdownFocused], targets: [.pane], cliName: "browser markdown-forward"
            ),
            // Column widths a resize saved with the file (MARKDOWN-TABLE-WIDTHS-DESIGN.md); the
            // table's right-click menu resets one table, this every table of the file.
            ActionDescriptor(
                id: "markdownResetTableWidths",
                title: String(localized: "action.markdownResetTableWidths", defaultValue: "Markdown: Reset Table Column Widths", bundle: .module),
                keywords: ["markdown", "table", "column", "width", "reset", "resize"],
                category: .browser, symbol: "tablecells", surfaces: [.palette],
                requires: [.markdownFocused], targets: [.pane], cliName: "browser markdown-reset-table-widths"
            ),
        ]
    }
}
