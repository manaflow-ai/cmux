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
            // Settings > Code Editor: the editor's defaults already follow VS Code, Cursor, Windsurf,
            // VSCodium or Zed (`editor.importFrom`); this writes them into cmux.json (only keys not
            // set there) so they show and stay as they are. It never writes the other editor's files.
            ActionDescriptor(
                id: "fileEditor.importEditorSettings",
                title: String(localized: "action.fileEditor.importEditorSettings",
                              defaultValue: "Copy Settings from VS Code or Zed", bundle: .module),
                keywords: ["editor", "import", "vscode", "zed", "cursor", "windsurf", "vscodium", "settings", "monaco"],
                category: .settings, symbol: "square.and.arrow.down", surfaces: [.palette],
                cliName: "settings import-editor-settings",
                // App-wide like the other headless settings verbs: nothing to right-click.
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // R96: the recovered drafts of unsaved files (a quit, crash or power-off) after the
            // launch notice has shown once; Return opens the chosen one as unsaved changes, as the
            // notice's Open does.
            ActionDescriptor(
                id: "file.openRecoveredDraft",
                title: String(localized: "action.file.openRecoveredDraft", defaultValue: "Open Recovered Draft…", bundle: .module),
                keywords: ["file", "editor", "recover", "recovered", "draft", "unsaved", "crash", "restore"],
                category: .pane, symbol: "doc.badge.clock", surfaces: [.palette], cliName: "file open-recovered-draft",
                // A palette page of drafts to pick from; scripts read the drafts with debug.filepages.
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
        ]
    }
}
