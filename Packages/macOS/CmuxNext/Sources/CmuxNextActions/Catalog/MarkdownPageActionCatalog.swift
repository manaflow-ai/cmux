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
            // K1: a read-only page owns bare keys, so a user may bind `g g` here (keybindings.json,
            // `when: markdownReadOnlyFocused`); no default key (customization.md section 7).
            ActionDescriptor(
                id: "markdownGoToTop",
                title: String(localized: "action.markdownGoToTop", defaultValue: "Markdown: Go to Top", bundle: .module),
                keywords: ["markdown", "vim", "top", "start"], category: .browser, symbol: "arrow.up.to.line.alt",
                surfaces: [.palette, .keyboard], requires: [.markdownReadOnlyFocused], targets: [.pane],
                cliName: "browser markdown-go-to-top"
            ),
        ]
    }
}
