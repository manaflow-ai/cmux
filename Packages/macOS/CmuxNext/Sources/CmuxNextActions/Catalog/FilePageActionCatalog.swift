// The code editor page's commands (diff-host S7); the markdown page's are in
// MarkdownPageActionCatalog. The page reads no chord: the one key dispatcher runs these while the
// page has the keyboard (`codeEditorFocused`, the trunk's rule: the focused page is `cmux.editor`) and the app sends the page command. The editor also
// takes the shared find actions and `saveFilePreview` / `toggleFileEditorWordWrap`.

nonisolated enum FilePageActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "fileEditorGotoLine",
                title: String(localized: "action.fileEditorGotoLine", defaultValue: "Editor: Go to Line…", bundle: .module),
                keywords: ["editor", "line", "jump"], defaultShortcut: Shortcut("g", modifiers: [.control]),
                category: .browser, symbol: "arrow.right.to.line", surfaces: [.keyboard], requires: [.codeEditorFocused],
                targets: [.pane], cliName: "browser editor-go-to-line"
            ),
            ActionDescriptor(
                id: "fileEditorReplace",
                title: String(localized: "action.fileEditorReplace", defaultValue: "Editor: Replace…", bundle: .module),
                keywords: ["editor", "find", "replace"], category: .browser, symbol: "arrow.left.arrow.right",
                surfaces: [.keyboard], requires: [.codeEditorFocused], targets: [.pane], cliName: "browser editor-replace"
            ),
            ActionDescriptor(
                id: "fileEditorZoomIn",
                title: String(localized: "action.fileEditorZoomIn", defaultValue: "Editor: Zoom In", bundle: .module),
                keywords: ["editor", "zoom", "font"], defaultShortcut: Shortcut("=", modifiers: [.command]),
                category: .browser, symbol: "plus.magnifyingglass", surfaces: [.keyboard], requires: [.codeEditorFocused],
                targets: [.pane], cliName: "browser editor-zoom-in"
            ),
            ActionDescriptor(
                id: "fileEditorZoomOut",
                title: String(localized: "action.fileEditorZoomOut", defaultValue: "Editor: Zoom Out", bundle: .module),
                keywords: ["editor", "zoom", "font"], defaultShortcut: Shortcut("-", modifiers: [.command]),
                category: .browser, symbol: "minus.magnifyingglass", surfaces: [.keyboard], requires: [.codeEditorFocused],
                targets: [.pane], cliName: "browser editor-zoom-out"
            ),
            ActionDescriptor(
                id: "fileEditorZoomReset",
                title: String(localized: "action.fileEditorZoomReset", defaultValue: "Editor: Actual Size", bundle: .module),
                keywords: ["editor", "zoom", "reset"], defaultShortcut: Shortcut("0", modifiers: [.command]),
                category: .browser, symbol: "1.magnifyingglass", surfaces: [.keyboard], requires: [.codeEditorFocused],
                targets: [.pane], cliName: "browser editor-actual-size"
            ),
            // Any Monaco action (webviews/src/pages/editor/keys.ts EDITOR_ACTIONS) for a user binding.
            ActionDescriptor(
                id: "fileEditorAction",
                title: String(localized: "action.fileEditorAction", defaultValue: "Editor: Run Editor Action", bundle: .module),
                keywords: ["editor", "monaco", "command"], category: .browser, symbol: "command",
                surfaces: [.keyboard], requires: [.codeEditorFocused], arguments: [CatalogArgument.textString],
                targets: [.pane], cliName: "browser editor-action"
            ),
        ]
    }
}
