// Catalog rows for one inventory domain. Titles live in Localizable.xcstrings (en, ja).

extension ActionCatalog {
    static func browserActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "browserBack",
                title: String(localized: "action.browserBack", defaultValue: "Back", bundle: .module),
                keywords: ["browser", "history"], defaultShortcut: Shortcut("[", modifiers: [.command]),
                category: .browser, symbol: "chevron.backward", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserForward",
                title: String(localized: "action.browserForward", defaultValue: "Forward", bundle: .module),
                keywords: ["browser", "history"], defaultShortcut: Shortcut("]", modifiers: [.command]),
                category: .browser, symbol: "chevron.forward", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserReload",
                title: String(localized: "action.browserReload", defaultValue: "Reload Page", bundle: .module),
                keywords: ["browser", "refresh"], defaultShortcut: Shortcut("r", modifiers: [.command]),
                category: .browser, symbol: "arrow.clockwise", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserHardReload",
                title: String(localized: "action.browserHardReload", defaultValue: "Hard Reload Page", bundle: .module),
                keywords: ["browser", "refresh", "cache"],
                defaultShortcut: Shortcut("r", modifiers: [.command, .shift]), category: .browser,
                symbol: "arrow.clockwise.circle", surfaces: [.palette, .keyboard, .menu], requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "focusBrowserAddressBar",
                title: String(localized: "action.focusBrowserAddressBar", defaultValue: "Focus Address Bar", bundle: .module),
                keywords: ["browser", "url", "omnibox"], defaultShortcut: Shortcut("l", modifiers: [.command]),
                category: .browser, symbol: "link.circle", surfaces: [.palette, .keyboard], requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserZoomIn",
                title: String(localized: "action.browserZoomIn", defaultValue: "Zoom In", bundle: .module),
                keywords: ["browser", "zoom"], defaultShortcut: Shortcut("=", modifiers: [.command]),
                category: .browser, symbol: "plus.magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserZoomOut",
                title: String(localized: "action.browserZoomOut", defaultValue: "Zoom Out", bundle: .module),
                keywords: ["browser", "zoom"], defaultShortcut: Shortcut("-", modifiers: [.command]),
                category: .browser, symbol: "minus.magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserZoomReset",
                title: String(localized: "action.browserZoomReset", defaultValue: "Actual Size", bundle: .module),
                keywords: ["browser", "zoom", "reset"], defaultShortcut: Shortcut("0", modifiers: [.command]),
                category: .browser, symbol: "1.magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "markdownZoomIn",
                title: String(localized: "action.markdownZoomIn", defaultValue: "Markdown: Zoom In", bundle: .module),
                keywords: ["markdown", "zoom"], defaultShortcut: Shortcut("=", modifiers: [.command]),
                category: .browser, symbol: "plus.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.markdownFocused]
            ),
            ActionDescriptor(
                id: "markdownZoomOut",
                title: String(localized: "action.markdownZoomOut", defaultValue: "Markdown: Zoom Out", bundle: .module),
                keywords: ["markdown", "zoom"], defaultShortcut: Shortcut("-", modifiers: [.command]),
                category: .browser, symbol: "minus.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.markdownFocused]
            ),
            ActionDescriptor(
                id: "markdownZoomReset",
                title: String(localized: "action.markdownZoomReset", defaultValue: "Markdown: Actual Size", bundle: .module),
                keywords: ["markdown", "zoom", "reset"], defaultShortcut: Shortcut("0", modifiers: [.command]),
                category: .browser, symbol: "1.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.markdownFocused]
            ),
            ActionDescriptor(
                id: "toggleBrowserDeveloperTools",
                title: String(localized: "action.toggleBrowserDeveloperTools", defaultValue: "Toggle Developer Tools", bundle: .module),
                keywords: ["browser", "devtools", "inspector"],
                defaultShortcut: Shortcut("i", modifiers: [.option, .command]), category: .browser, symbol: "hammer",
                surfaces: [.palette, .keyboard, .menu], requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "showBrowserJavaScriptConsole",
                title: String(localized: "action.showBrowserJavaScriptConsole", defaultValue: "Show JavaScript Console", bundle: .module),
                keywords: ["browser", "devtools", "console"],
                defaultShortcut: Shortcut("c", modifiers: [.option, .command]), category: .browser, symbol: "terminal",
                surfaces: [.palette, .keyboard, .menu], requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "toggleBrowserFocusMode",
                title: String(localized: "action.toggleBrowserFocusMode", defaultValue: "Toggle Browser Focus Mode", bundle: .module),
                keywords: ["browser", "distraction"],
                defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: [.option, .command]), category: .browser,
                symbol: "eye", surfaces: [.palette, .keyboard, .menu, .contextMenu], requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "toggleBrowserDesignMode",
                title: String(localized: "action.toggleBrowserDesignMode", defaultValue: "Toggle Browser Design Mode", bundle: .module),
                keywords: ["browser", "edit"], defaultShortcut: Shortcut("d", modifiers: [.control, .option, .command]),
                category: .browser, symbol: "paintbrush.pointed", surfaces: [.keyboard, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "toggleReactGrab",
                title: String(localized: "action.toggleReactGrab", defaultValue: "Toggle React Grab", bundle: .module),
                keywords: ["browser", "react", "inspect"],
                defaultShortcut: Shortcut("g", modifiers: [.command, .shift]), category: .browser,
                symbol: "hand.point.up.left", surfaces: [.palette, .keyboard, .menu], requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "splitBrowserRight",
                title: String(localized: "action.splitBrowserRight", defaultValue: "Split Browser Right", bundle: .module),
                keywords: ["browser", "split"], defaultShortcut: Shortcut("d", modifiers: [.option, .command]),
                category: .browser, symbol: "rectangle.righthalf.inset.filled", surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "splitBrowserDown",
                title: String(localized: "action.splitBrowserDown", defaultValue: "Split Browser Down", bundle: .module),
                keywords: ["browser", "split"], defaultShortcut: Shortcut("d", modifiers: [.shift, .option, .command]),
                category: .browser, symbol: "rectangle.bottomhalf.inset.filled", surfaces: [.palette, .keyboard, .menu]
            ),
            ActionDescriptor(
                id: "palette.browserOpenDefault",
                title: String(localized: "action.palette.browserOpenDefault", defaultValue: "Open in Default Browser", bundle: .module),
                keywords: ["browser", "external"], category: .browser, symbol: "safari", surfaces: [.palette, .menu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "palette.browserToggleOmnibar",
                title: String(localized: "action.palette.browserToggleOmnibar", defaultValue: "Toggle Omnibar", bundle: .module),
                keywords: ["browser", "address bar"], category: .browser, symbol: "rectangle.topthird.inset.filled",
                surfaces: [.palette], requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "palette.browserClearHistory",
                title: String(localized: "action.palette.browserClearHistory", defaultValue: "Clear Browser History", bundle: .module),
                keywords: ["browser", "privacy"], category: .browser, symbol: "clock.badge.xmark", surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "importFromBrowser",
                title: String(localized: "action.importFromBrowser", defaultValue: "Import Browser Data…", bundle: .module),
                keywords: ["browser", "bookmarks", "cookies"], category: .browser,
                symbol: "square.and.arrow.down.on.square", surfaces: [.menu, .contextMenu]
            ),
            ActionDescriptor(
                id: "palette.enableBrowser",
                title: String(localized: "action.palette.enableBrowser", defaultValue: "Enable cmux Browser", bundle: .module),
                keywords: ["browser", "enable"], category: .browser, symbol: "globe", surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.disableBrowser",
                title: String(localized: "action.palette.disableBrowser", defaultValue: "Disable cmux Browser", bundle: .module),
                keywords: ["browser", "disable"], category: .browser, symbol: "globe.badge.chevron.backward",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "openLinkInNewTab",
                title: String(localized: "action.openLinkInNewTab", defaultValue: "Open Link in New Tab", bundle: .module),
                keywords: ["browser", "link"], category: .browser, symbol: "arrow.up.right.square",
                surfaces: [.contextMenu], requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "openLinkInDefaultBrowser",
                title: String(localized: "action.openLinkInDefaultBrowser", defaultValue: "Open Link in Default Browser", bundle: .module),
                keywords: ["browser", "link", "external"], category: .browser, symbol: "arrow.up.forward.app",
                surfaces: [.contextMenu], requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserScreenshotPage",
                title: String(localized: "action.browserScreenshotPage", defaultValue: "Screenshot Page", bundle: .module),
                keywords: ["browser", "capture"], category: .browser, symbol: "camera", surfaces: [.contextMenu],
                requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserScreenshotSection",
                title: String(localized: "action.browserScreenshotSection", defaultValue: "Screenshot Section", bundle: .module),
                keywords: ["browser", "capture"], category: .browser, symbol: "camera.viewfinder",
                surfaces: [.contextMenu], requires: [.browserFocused]
            ),
            ActionDescriptor(
                id: "browserTheme",
                title: String(localized: "action.browserTheme", defaultValue: "Browser Theme…", bundle: .module),
                keywords: ["browser", "appearance", "dark"], category: .browser, symbol: "circle.righthalf.filled",
                surfaces: [.contextMenu], requires: [.browserFocused], input: .list
            ),
            ActionDescriptor(
                id: "browserNewProfile",
                title: String(localized: "action.browserNewProfile", defaultValue: "New Browser Profile…", bundle: .module),
                keywords: ["browser", "profile"], category: .browser, symbol: "person.crop.circle.badge.plus",
                surfaces: [.contextMenu], input: .text
            ),
            ActionDescriptor(
                id: "browserRenameProfile",
                title: String(localized: "action.browserRenameProfile", defaultValue: "Rename Browser Profile…", bundle: .module),
                keywords: ["browser", "profile"], category: .browser, symbol: "person.crop.circle",
                surfaces: [.contextMenu], input: .text
            ),
            ActionDescriptor(
                id: "saveFilePreview",
                title: String(localized: "action.saveFilePreview", defaultValue: "Save File", bundle: .module),
                keywords: ["file", "editor"], defaultShortcut: Shortcut("s", modifiers: [.command]), category: .browser,
                symbol: "square.and.arrow.down", surfaces: [.keyboard, .menu], requires: [.filePreviewFocused]
            ),
            ActionDescriptor(
                id: "toggleFileEditorWordWrap",
                title: String(localized: "action.toggleFileEditorWordWrap", defaultValue: "Toggle Word Wrap", bundle: .module),
                keywords: ["file", "editor", "wrap"], defaultShortcut: Shortcut("z", modifiers: [.option]),
                category: .browser, symbol: "text.word.spacing", surfaces: [.keyboard], requires: [.filePreviewFocused]
            ),
            ActionDescriptor(
                id: "filePreviewOpenWith",
                title: String(localized: "action.filePreviewOpenWith", defaultValue: "Open File With…", bundle: .module),
                keywords: ["file", "open in"], category: .browser, symbol: "arrow.up.forward.app",
                surfaces: [.contextMenu], requires: [.filePreviewFocused], input: .list
            ),
            ActionDescriptor(
                id: "filePreviewOpenExternally",
                title: String(localized: "action.filePreviewOpenExternally", defaultValue: "Open File Externally", bundle: .module),
                keywords: ["file", "external"], category: .browser, symbol: "arrow.up.right.square",
                surfaces: [.contextMenu], requires: [.filePreviewFocused]
            ),
            ActionDescriptor(
                id: "filePreviewRevealInFinder",
                title: String(localized: "action.filePreviewRevealInFinder", defaultValue: "Reveal File in Finder", bundle: .module),
                keywords: ["file", "finder"], category: .browser, symbol: "folder", surfaces: [.contextMenu],
                requires: [.filePreviewFocused]
            ),
            ActionDescriptor(
                id: "openDiffViewer",
                title: String(localized: "action.openDiffViewer", defaultValue: "Open Diff Viewer", bundle: .module),
                keywords: ["git", "diff", "changes"],
                defaultShortcut: Shortcut("d", modifiers: [.control, .shift, .command]), category: .browser,
                symbol: "plusminus", surfaces: [.palette, .keyboard]
            ),
            ActionDescriptor(
                id: "palette.openDirectoryDiffViewer",
                title: String(localized: "action.palette.openDirectoryDiffViewer", defaultValue: "Open Directory Diff Viewer", bundle: .module),
                keywords: ["git", "diff", "changes"], category: .browser, symbol: "plus.forwardslash.minus",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "diffViewerNextLine",
                title: String(localized: "action.diffViewerNextLine", defaultValue: "Diff: Next Line", bundle: .module),
                keywords: ["diff", "vim"], defaultShortcut: Shortcut("j", modifiers: []), category: .browser,
                symbol: "arrow.down", surfaces: [.keyboard], requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerPreviousLine",
                title: String(localized: "action.diffViewerPreviousLine", defaultValue: "Diff: Previous Line", bundle: .module),
                keywords: ["diff", "vim"], defaultShortcut: Shortcut("k", modifiers: []), category: .browser,
                symbol: "arrow.up", surfaces: [.keyboard], requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerHalfPageDown",
                title: String(localized: "action.diffViewerHalfPageDown", defaultValue: "Diff: Half Page Down", bundle: .module),
                keywords: ["diff", "vim", "scroll"], defaultShortcut: Shortcut("d", modifiers: [.control]),
                category: .browser, symbol: "arrow.down.to.line", surfaces: [.keyboard], requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerHalfPageUp",
                title: String(localized: "action.diffViewerHalfPageUp", defaultValue: "Diff: Half Page Up", bundle: .module),
                keywords: ["diff", "vim", "scroll"], defaultShortcut: Shortcut("u", modifiers: [.control]),
                category: .browser, symbol: "arrow.up.to.line", surfaces: [.keyboard], requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerNextHunk",
                title: String(localized: "action.diffViewerNextHunk", defaultValue: "Diff: Next Hunk", bundle: .module),
                keywords: ["diff", "vim"], defaultShortcut: Shortcut("n", modifiers: [.control]), category: .browser,
                symbol: "chevron.down.2", surfaces: [.keyboard], requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerPreviousHunk",
                title: String(localized: "action.diffViewerPreviousHunk", defaultValue: "Diff: Previous Hunk", bundle: .module),
                keywords: ["diff", "vim"], defaultShortcut: Shortcut("p", modifiers: [.control]), category: .browser,
                symbol: "chevron.up.2", surfaces: [.keyboard], requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerGoToBottom",
                title: String(localized: "action.diffViewerGoToBottom", defaultValue: "Diff: Go to Bottom", bundle: .module),
                keywords: ["diff", "vim", "end"], defaultShortcut: Shortcut("g", modifiers: [.shift]),
                shortcutLabel: "G", category: .browser, symbol: "arrow.down.to.line.alt", surfaces: [.keyboard],
                requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerGoToTop",
                title: String(localized: "action.diffViewerGoToTop", defaultValue: "Diff: Go to Top", bundle: .module),
                keywords: ["diff", "vim", "start"], shortcutLabel: "g g", category: .browser,
                symbol: "arrow.up.to.line.alt", surfaces: [.keyboard], requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerSearch",
                title: String(localized: "action.diffViewerSearch", defaultValue: "Diff: Search", bundle: .module),
                keywords: ["diff", "vim", "find"], defaultShortcut: Shortcut("/", modifiers: []), category: .browser,
                symbol: "magnifyingglass", surfaces: [.keyboard], requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerNextFile",
                title: String(localized: "action.diffViewerNextFile", defaultValue: "Diff: Next File", bundle: .module),
                keywords: ["diff", "vim"], shortcutLabel: "] f", category: .browser, symbol: "doc.badge.arrow.up",
                surfaces: [.keyboard], requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "diffViewerPreviousFile",
                title: String(localized: "action.diffViewerPreviousFile", defaultValue: "Diff: Previous File", bundle: .module),
                keywords: ["diff", "vim"], shortcutLabel: "[ f", category: .browser, symbol: "doc.badge.clock",
                surfaces: [.keyboard], requires: [.diffViewerFocused]
            ),
            ActionDescriptor(
                id: "palette.vscodeServeWebStop",
                title: String(localized: "action.palette.vscodeServeWebStop", defaultValue: "Stop VS Code Inline Server", bundle: .module),
                keywords: ["vscode", "editor", "server"], category: .browser, symbol: "stop.fill", surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.vscodeServeWebRestart",
                title: String(localized: "action.palette.vscodeServeWebRestart", defaultValue: "Restart VS Code Inline Server", bundle: .module),
                keywords: ["vscode", "editor", "server"], category: .browser, symbol: "arrow.clockwise.circle",
                surfaces: [.palette]
            ),
        ]
    }
}
