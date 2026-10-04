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
        ]
    }
}
