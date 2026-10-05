// The viewers' open actions (R89): each asks with the cmux picker when it
// has no folder or file to open. Diff and file viewer actions that need a
// focused viewer stay in BrowserActionCatalog.

nonisolated enum ViewerActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            // The focused pane's repository; without one, the cmux picker (R89).
            ActionDescriptor(
                id: "openDiffViewer",
                title: String(localized: "action.openDiffViewer", defaultValue: "Open Diff Viewer", bundle: .module),
                keywords: ["git", "diff", "changes"],
                // Cmd-Ctrl-Shift-D is New Row (New Column is Cmd-Ctrl-D); G for git.
                defaultShortcut: Shortcut("g", modifiers: [.control, .shift, .command]), category: .browser,
                symbol: "plusminus", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "browser open-diff-viewer", mainMenu: .file,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            // Always the cmux picker, in folder mode (R89).
            ActionDescriptor(
                id: "palette.openDirectoryDiffViewer",
                title: String(localized: "action.palette.openDirectoryDiffViewer", defaultValue: "Open Diff Viewer in Folder…", bundle: .module),
                keywords: ["git", "diff", "changes", "folder", "directory"], category: .browser, symbol: "plus.forwardslash.minus",
                surfaces: [.palette, .keyboard, .menu], targets: [.pane], cliName: "browser open-directory-diff-viewer", mainMenu: .file,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            // The picker in file mode, Markdown only, at the pane's folder; with
            // a path it opens that file. Until the Markdown page (diff-host S6)
            // lands, the file opens in the file preview.
            ActionDescriptor(
                id: "openMarkdownFile",
                title: String(localized: "action.openMarkdownFile", defaultValue: "Open Markdown File…", bundle: .module),
                keywords: ["markdown", "md", "preview", "viewer", "file"], category: .browser, symbol: "doc.richtext",
                surfaces: [.palette, .keyboard, .menu], arguments: [CatalogArgument.optionalPathString], targets: [.pane],
                cliName: "browser open-markdown-file", mainMenu: .file,
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
        ]
    }
}
