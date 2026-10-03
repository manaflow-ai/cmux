// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum BrowserActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "browserBack",
                title: String(localized: "action.browserBack", defaultValue: "Back", bundle: .module),
                keywords: ["browser", "history"], defaultShortcut: Shortcut("[", modifiers: [.command]),
                category: .browser, symbol: "chevron.backward", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser back", mainMenu: .view
            ),
            ActionDescriptor(
                id: "browserForward",
                title: String(localized: "action.browserForward", defaultValue: "Forward", bundle: .module),
                keywords: ["browser", "history"], defaultShortcut: Shortcut("]", modifiers: [.command]),
                category: .browser, symbol: "chevron.forward", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser forward", mainMenu: .view
            ),
            ActionDescriptor(
                id: "browserReload",
                title: String(localized: "action.browserReload", defaultValue: "Reload Page", bundle: .module),
                keywords: ["browser", "refresh"], defaultShortcut: Shortcut("r", modifiers: [.command]),
                category: .browser, symbol: "arrow.clockwise", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser reload-page", mainMenu: .view
            ),
            ActionDescriptor(
                id: "browserHardReload",
                title: String(localized: "action.browserHardReload", defaultValue: "Hard Reload Page", bundle: .module),
                keywords: ["browser", "refresh", "cache"],
                defaultShortcut: Shortcut("r", modifiers: [.command, .shift]), category: .browser,
                symbol: "arrow.clockwise.circle", surfaces: [.palette, .keyboard, .menu], requires: [.browserFocused],
                targets: [.pane], cliName: "browser hard-reload-page", mainMenu: .view
            ),
            ActionDescriptor(
                id: "browser.openInChromium",
                title: String(localized: "action.browser.openInChromium", defaultValue: "Open in Chromium", bundle: .module),
                keywords: ["browser", "engine", "chrome", "chromium", "cef", "switch"],
                category: .browser, symbol: "circle.circle", surfaces: [.palette, .contextMenu], requires: [.browserFocused],
                targets: [.tab], cliName: "browser open-in-chromium"
            ),
            ActionDescriptor(
                id: "browser.openInWebKit",
                title: String(localized: "action.browser.openInWebKit", defaultValue: "Open in WebKit", bundle: .module),
                keywords: ["browser", "engine", "safari", "webkit", "switch"],
                category: .browser, symbol: "safari", surfaces: [.palette, .contextMenu], requires: [.browserFocused],
                targets: [.tab], cliName: "browser open-in-webkit"
            ),
            ActionDescriptor(
                id: "focusBrowserAddressBar",
                title: String(localized: "action.focusBrowserAddressBar", defaultValue: "Focus Address Bar", bundle: .module),
                keywords: ["browser", "url", "omnibox"],
                category: .browser, symbol: "link.circle", surfaces: [.palette, .keyboard], requires: [.browserFocused],
                targets: [.pane], cliName: "browser focus-address-bar"
            ),
            ActionDescriptor(
                id: "browserZoomIn",
                title: String(localized: "action.browserZoomIn", defaultValue: "Zoom In", bundle: .module),
                keywords: ["browser", "zoom"], defaultShortcut: Shortcut("=", modifiers: [.command]),
                category: .browser, symbol: "plus.magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser zoom-in", mainMenu: .view
            ),
            ActionDescriptor(
                id: "browserZoomOut",
                title: String(localized: "action.browserZoomOut", defaultValue: "Zoom Out", bundle: .module),
                keywords: ["browser", "zoom"], defaultShortcut: Shortcut("-", modifiers: [.command]),
                category: .browser, symbol: "minus.magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser zoom-out", mainMenu: .view
            ),
            ActionDescriptor(
                id: "browserZoomReset",
                title: String(localized: "action.browserZoomReset", defaultValue: "Actual Size", bundle: .module),
                keywords: ["browser", "zoom", "reset"], defaultShortcut: Shortcut("0", modifiers: [.command]),
                category: .browser, symbol: "1.magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser actual-size", mainMenu: .view
            ),
            ActionDescriptor(
                id: "markdownZoomIn",
                title: String(localized: "action.markdownZoomIn", defaultValue: "Markdown: Zoom In", bundle: .module),
                keywords: ["markdown", "zoom"], defaultShortcut: Shortcut("=", modifiers: [.command]),
                category: .browser, symbol: "plus.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.markdownFocused], targets: [.pane], cliName: "browser markdown-zoom-in"
            ),
            ActionDescriptor(
                id: "markdownZoomOut",
                title: String(localized: "action.markdownZoomOut", defaultValue: "Markdown: Zoom Out", bundle: .module),
                keywords: ["markdown", "zoom"], defaultShortcut: Shortcut("-", modifiers: [.command]),
                category: .browser, symbol: "minus.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.markdownFocused], targets: [.pane], cliName: "browser markdown-zoom-out"
            ),
            ActionDescriptor(
                id: "markdownZoomReset",
                title: String(localized: "action.markdownZoomReset", defaultValue: "Markdown: Actual Size", bundle: .module),
                keywords: ["markdown", "zoom", "reset"], defaultShortcut: Shortcut("0", modifiers: [.command]),
                category: .browser, symbol: "1.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.markdownFocused], targets: [.pane], cliName: "browser markdown-actual-size"
            ),
            ActionDescriptor(
                id: "toggleBrowserDeveloperTools",
                title: String(localized: "action.toggleBrowserDeveloperTools", defaultValue: "Toggle Developer Tools", bundle: .module),
                keywords: ["browser", "devtools", "inspector"],
                defaultShortcut: Shortcut("i", modifiers: [.option, .command]), category: .browser, symbol: "hammer",
                surfaces: [.palette, .keyboard, .menu], requires: [.browserFocused], targets: [.pane],
                cliName: "browser toggle-developer-tools", mainMenu: .view
            ),
            ActionDescriptor(
                id: "showBrowserJavaScriptConsole",
                title: String(localized: "action.showBrowserJavaScriptConsole", defaultValue: "Show JavaScript Console", bundle: .module),
                keywords: ["browser", "devtools", "console"],
                defaultShortcut: Shortcut("j", modifiers: [.option, .command]), category: .browser, symbol: "terminal",
                surfaces: [.palette, .keyboard, .menu], requires: [.browserFocused], targets: [.pane],
                cliName: "browser show-javascript-console", mainMenu: .view
            ),
            ActionDescriptor(
                id: "inspectBrowserElement",
                title: String(localized: "action.inspectBrowserElement", defaultValue: "Inspect Element", bundle: .module),
                keywords: ["browser", "devtools", "inspector", "element", "picker"],
                defaultShortcut: Shortcut("c", modifiers: [.option, .command]), category: .browser, symbol: "cursorarrow.rays",
                surfaces: [.palette, .keyboard, .menu], requires: [.browserFocused], targets: [.pane],
                cliName: "browser inspect-element", mainMenu: .view
            ),
            ActionDescriptor(
                id: "toggleBrowserFocusMode",
                title: String(localized: "action.toggleBrowserFocusMode", defaultValue: "Toggle Browser Focus Mode", bundle: .module),
                keywords: ["browser", "distraction"],
                defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: [.option, .command]), category: .browser,
                symbol: "eye", surfaces: [.palette, .keyboard, .menu, .contextMenu], requires: [.browserFocused],
                targets: [.pane], cliName: "browser toggle-focus-mode", mainMenu: .view
            ),
            ActionDescriptor(
                id: "toggleBrowserDesignMode",
                title: String(localized: "action.toggleBrowserDesignMode", defaultValue: "Toggle Browser Design Mode", bundle: .module),
                keywords: ["browser", "edit"], defaultShortcut: Shortcut("d", modifiers: [.control, .option, .command]),
                category: .browser, symbol: "paintbrush.pointed", surfaces: [.keyboard, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser toggle-design-mode", mainMenu: .view
            ),
            ActionDescriptor(
                id: "toggleReactGrab",
                title: String(localized: "action.toggleReactGrab", defaultValue: "Toggle React Grab", bundle: .module),
                keywords: ["browser", "react", "inspect"],
                defaultShortcut: Shortcut("g", modifiers: [.command, .shift]), category: .browser,
                symbol: "hand.point.up.left", surfaces: [.palette, .keyboard, .menu], requires: [.browserFocused],
                targets: [.pane], cliName: "browser toggle-react-grab", mainMenu: .view
            ),
            // Single letters in a Chromium page with no text field focused
            // (the page saw the key first): label the links on screen.
            ActionDescriptor(
                id: "browserLinkHints",
                title: String(localized: "action.browserLinkHints", defaultValue: "Open Link by Hint", bundle: .module),
                keywords: ["browser", "link", "hint", "vimium", "keyboard", "click"], defaultShortcut: Shortcut("f", modifiers: []),
                category: .browser, symbol: "character.cursor.ibeam", surfaces: [.palette, .keyboard],
                requires: [.browserFocused], targets: [.pane], cliName: "browser link-hints"
            ),
            ActionDescriptor(
                id: "browserLinkHintsNewSplit",
                title: String(localized: "action.browserLinkHintsNewSplit", defaultValue: "Open Link by Hint in New Split", bundle: .module),
                keywords: ["browser", "link", "hint", "vimium", "keyboard", "split"], defaultShortcut: Shortcut("f", modifiers: [.shift]),
                category: .browser, symbol: "rectangle.righthalf.inset.filled", surfaces: [.palette, .keyboard],
                requires: [.browserFocused], targets: [.pane], cliName: "browser link-hints-split"
            ),
            ActionDescriptor(
                id: "splitBrowserRight",
                title: String(localized: "action.splitBrowserRight", defaultValue: "Split Browser Right", bundle: .module),
                keywords: ["browser", "split"], defaultShortcut: Shortcut("d", modifiers: [.option, .command]),
                category: .browser, symbol: "rectangle.righthalf.inset.filled", surfaces: [.palette, .keyboard, .menu],
                targets: [.pane], cliName: "browser split-right", mainMenu: .view
            ),
            ActionDescriptor(
                id: "splitBrowserDown",
                title: String(localized: "action.splitBrowserDown", defaultValue: "Split Browser Down", bundle: .module),
                keywords: ["browser", "split"], defaultShortcut: Shortcut("d", modifiers: [.shift, .option, .command]),
                category: .browser, symbol: "rectangle.bottomhalf.inset.filled", surfaces: [.palette, .keyboard, .menu],
                targets: [.pane], cliName: "browser split-down", mainMenu: .view
            ),
            ActionDescriptor(
                id: "palette.browserOpenDefault",
                title: String(localized: "action.palette.browserOpenDefault", defaultValue: "Open in Default Browser", bundle: .module),
                keywords: ["browser", "external"], category: .browser, symbol: "safari", surfaces: [.palette, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser open-in-default", mainMenu: .view
            ),
            ActionDescriptor(
                id: "palette.browserToggleOmnibar",
                title: String(localized: "action.palette.browserToggleOmnibar", defaultValue: "Toggle Omnibar", bundle: .module),
                keywords: ["browser", "address bar"], category: .browser, symbol: "rectangle.topthird.inset.filled",
                surfaces: [.palette], requires: [.browserFocused], targets: [.pane], cliName: "browser toggle-omnibar"
            ),
            ActionDescriptor(
                id: "palette.browserClearHistory",
                title: String(localized: "action.palette.browserClearHistory", defaultValue: "Clear Browser History", bundle: .module),
                keywords: ["browser", "privacy"], category: .browser, symbol: "clock.badge.xmark", surfaces: [.palette],
                targets: [.pane], cliName: "browser clear-history"
            ),
            ActionDescriptor(
                id: "importFromBrowser",
                title: String(localized: "action.importFromBrowser2", defaultValue: "Import from Browser…", bundle: .module),
                keywords: ["browser", "bookmarks", "cookies"], category: .browser,
                symbol: "square.and.arrow.down.on.square", surfaces: [.menu, .contextMenu], targets: [.pane],
                cliName: "browser import-data", mainMenu: .view
            ),
            {
                var importCSV = ActionDescriptor(
                    id: "password.importCSV",
                    title: String(localized: "action.password.importCSV", defaultValue: "Import Passwords from CSV…", bundle: .module),
                    keywords: ["passwords", "import", "csv", "chrome", "edge", "safari", "firefox", "1password", "bitwarden"],
                    category: .browser, symbol: "key", surfaces: [.palette, .keyboard, .menu], mainMenu: .file
                )
                // An agent must not be able to put the file picker in front of the person.
                importCSV.isPersonOnly = true
                return importCSV
            }(),
            ActionDescriptor(
                id: "palette.enableBrowser",
                title: String(localized: "action.palette.enableBrowser", defaultValue: "Enable cmux Browser", bundle: .module),
                keywords: ["browser", "enable"], category: .browser, symbol: "globe", surfaces: [.palette],
                targets: [.pane], cliName: "browser enable"
            ),
            ActionDescriptor(
                id: "palette.disableBrowser",
                title: String(localized: "action.palette.disableBrowser", defaultValue: "Disable cmux Browser", bundle: .module),
                keywords: ["browser", "disable"], category: .browser, symbol: "globe.badge.chevron.backward",
                surfaces: [.palette], targets: [.pane], cliName: "browser disable"
            ),
            ActionDescriptor(
                id: "openLinkInNewTab",
                title: String(localized: "action.openLinkInNewTab", defaultValue: "Open Link in New Tab", bundle: .module),
                keywords: ["browser", "link"], category: .browser, symbol: "arrow.up.right.square",
                surfaces: [.contextMenu], requires: [.browserFocused], targets: [.pane],
                cliName: "browser open-link-in-new-tab"
            ),
            ActionDescriptor(
                id: "openLinkInDefaultBrowser",
                title: String(localized: "action.openLinkInDefaultBrowser", defaultValue: "Open Link in Default Browser", bundle: .module),
                keywords: ["browser", "link", "external"], category: .browser, symbol: "arrow.up.forward.app",
                surfaces: [.contextMenu], requires: [.browserFocused], targets: [.pane],
                cliName: "browser open-link-in-default"
            ),
            ActionDescriptor(
                id: "browserScreenshotPage",
                title: String(localized: "action.browserScreenshotPage", defaultValue: "Screenshot Page", bundle: .module),
                keywords: ["browser", "capture"], category: .browser, symbol: "camera", surfaces: [.contextMenu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser screenshot-page"
            ),
            ActionDescriptor(
                id: "browserScreenshotSection",
                title: String(localized: "action.browserScreenshotSection", defaultValue: "Screenshot Section", bundle: .module),
                keywords: ["browser", "capture"], category: .browser, symbol: "camera.viewfinder",
                surfaces: [.contextMenu], requires: [.browserFocused], targets: [.pane],
                cliName: "browser screenshot-section"
            ),
            ActionDescriptor(
                id: "browserTheme",
                title: String(localized: "action.browserTheme", defaultValue: "Browser Theme…", bundle: .module),
                keywords: ["browser", "appearance", "dark"], category: .browser, symbol: "circle.righthalf.filled",
                surfaces: [.contextMenu], requires: [.browserFocused], arguments: [CatalogArgument.themeChoice],
                targets: [.pane], cliName: "browser theme"
            ),
            ActionDescriptor(
                id: "saveFilePreview",
                title: String(localized: "action.saveFilePreview", defaultValue: "Save File", bundle: .module),
                keywords: ["file", "editor"], defaultShortcut: Shortcut("s", modifiers: [.command]), category: .browser,
                symbol: "square.and.arrow.down", surfaces: [.keyboard, .menu], requires: [.filePreviewFocused],
                targets: [.pane], cliName: "browser save-file", mainMenu: .view
            ),
            ActionDescriptor(
                id: "toggleFileEditorWordWrap",
                title: String(localized: "action.toggleFileEditorWordWrap", defaultValue: "Toggle Word Wrap", bundle: .module),
                keywords: ["file", "editor", "wrap"], defaultShortcut: Shortcut("z", modifiers: [.option]),
                category: .browser, symbol: "text.word.spacing", surfaces: [.keyboard], requires: [.filePreviewFocused],
                targets: [.pane], cliName: "browser toggle-word-wrap"
            ),
            ActionDescriptor(
                id: "filePreviewOpenWith",
                title: String(localized: "action.filePreviewOpenWith", defaultValue: "Open File With…", bundle: .module),
                keywords: ["file", "open in"], category: .browser, symbol: "arrow.up.forward.app",
                surfaces: [.contextMenu], requires: [.filePreviewFocused], arguments: [CatalogArgument.appString],
                targets: [.pane], cliName: "browser open-file-with"
            ),
            ActionDescriptor(
                id: "filePreviewOpenExternally",
                title: String(localized: "action.filePreviewOpenExternally", defaultValue: "Open File Externally", bundle: .module),
                keywords: ["file", "external"], category: .browser, symbol: "arrow.up.right.square",
                surfaces: [.contextMenu], requires: [.filePreviewFocused], targets: [.pane],
                cliName: "browser open-file-externally"
            ),
            ActionDescriptor(
                id: "filePreviewRevealInFinder",
                title: String(localized: "action.filePreviewRevealInFinder", defaultValue: "Reveal File in Finder", bundle: .module),
                keywords: ["file", "finder"], category: .browser, symbol: "folder", surfaces: [.contextMenu],
                requires: [.filePreviewFocused], targets: [.pane], cliName: "browser reveal-file-in-finder"
            ),
            ActionDescriptor(
                id: "openDiffViewer",
                title: String(localized: "action.openDiffViewer", defaultValue: "Open Diff Viewer", bundle: .module),
                keywords: ["git", "diff", "changes"],
                // Cmd-Ctrl-Shift-D is New Row (New Column is Cmd-Ctrl-D); G for git.
                defaultShortcut: Shortcut("g", modifiers: [.control, .shift, .command]), category: .browser,
                symbol: "plusminus", surfaces: [.palette, .keyboard], targets: [.pane],
                cliName: "browser open-diff-viewer"
            ),
            ActionDescriptor(
                id: "palette.openDirectoryDiffViewer",
                title: String(localized: "action.palette.openDirectoryDiffViewer", defaultValue: "Open Directory Diff Viewer", bundle: .module),
                keywords: ["git", "diff", "changes"], category: .browser, symbol: "plus.forwardslash.minus",
                surfaces: [.palette], targets: [.pane], cliName: "browser open-directory-diff-viewer"
            ),
            ActionDescriptor(
                id: "diffViewerNextLine",
                title: String(localized: "action.diffViewerNextLine", defaultValue: "Diff: Next Line", bundle: .module),
                keywords: ["diff", "vim"], defaultShortcut: Shortcut("j", modifiers: []), category: .browser,
                symbol: "arrow.down", surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-next-line"
            ),
            ActionDescriptor(
                id: "diffViewerPreviousLine",
                title: String(localized: "action.diffViewerPreviousLine", defaultValue: "Diff: Previous Line", bundle: .module),
                keywords: ["diff", "vim"], defaultShortcut: Shortcut("k", modifiers: []), category: .browser,
                symbol: "arrow.up", surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-previous-line"
            ),
            ActionDescriptor(
                id: "diffViewerHalfPageDown",
                title: String(localized: "action.diffViewerHalfPageDown", defaultValue: "Diff: Half Page Down", bundle: .module),
                keywords: ["diff", "vim", "scroll"], defaultShortcut: Shortcut("d", modifiers: [.control]),
                category: .browser, symbol: "arrow.down.to.line", surfaces: [.keyboard], requires: [.diffViewerFocused],
                targets: [.pane], cliName: "browser diff-half-page-down"
            ),
            ActionDescriptor(
                id: "diffViewerHalfPageUp",
                title: String(localized: "action.diffViewerHalfPageUp", defaultValue: "Diff: Half Page Up", bundle: .module),
                keywords: ["diff", "vim", "scroll"], defaultShortcut: Shortcut("u", modifiers: [.control]),
                category: .browser, symbol: "arrow.up.to.line", surfaces: [.keyboard], requires: [.diffViewerFocused],
                targets: [.pane], cliName: "browser diff-half-page-up"
            ),
            ActionDescriptor(
                id: "diffViewerNextHunk",
                title: String(localized: "action.diffViewerNextHunk", defaultValue: "Diff: Next Hunk", bundle: .module),
                keywords: ["diff", "vim"], defaultShortcut: Shortcut("n", modifiers: [.control]), category: .browser,
                symbol: "chevron.down.2", surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-next-hunk"
            ),
            ActionDescriptor(
                id: "diffViewerPreviousHunk",
                title: String(localized: "action.diffViewerPreviousHunk", defaultValue: "Diff: Previous Hunk", bundle: .module),
                keywords: ["diff", "vim"], defaultShortcut: Shortcut("p", modifiers: [.control]), category: .browser,
                symbol: "chevron.up.2", surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-previous-hunk"
            ),
            ActionDescriptor(
                id: "diffViewerGoToBottom",
                title: String(localized: "action.diffViewerGoToBottom", defaultValue: "Diff: Go to Bottom", bundle: .module),
                keywords: ["diff", "vim", "end"], defaultShortcut: Shortcut("g", modifiers: [.shift]),
                shortcutLabel: "G", category: .browser, symbol: "arrow.down.to.line.alt", surfaces: [.keyboard],
                requires: [.diffViewerFocused], targets: [.pane], cliName: "browser diff-go-to-bottom"
            ),
            ActionDescriptor(
                id: "diffViewerGoToTop",
                title: String(localized: "action.diffViewerGoToTop", defaultValue: "Diff: Go to Top", bundle: .module),
                keywords: ["diff", "vim", "start"], shortcutLabel: "g g", category: .browser,
                symbol: "arrow.up.to.line.alt", surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-go-to-top"
            ),
            ActionDescriptor(
                id: "diffViewerSearch",
                title: String(localized: "action.diffViewerSearch", defaultValue: "Diff: Search", bundle: .module),
                keywords: ["diff", "vim", "find"], defaultShortcut: Shortcut("/", modifiers: []), category: .browser,
                symbol: "magnifyingglass", surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-search"
            ),
            ActionDescriptor(
                id: "diffViewerNextFile",
                title: String(localized: "action.diffViewerNextFile", defaultValue: "Diff: Next File", bundle: .module),
                keywords: ["diff", "vim"], shortcutLabel: "] f", category: .browser, symbol: "doc.badge.arrow.up",
                surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-next-file"
            ),
            ActionDescriptor(
                id: "diffViewerPreviousFile",
                title: String(localized: "action.diffViewerPreviousFile", defaultValue: "Diff: Previous File", bundle: .module),
                keywords: ["diff", "vim"], shortcutLabel: "[ f", category: .browser, symbol: "doc.badge.clock",
                surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-previous-file"
            ),
            ActionDescriptor(
                id: "palette.vscodeServeWebStop",
                title: String(localized: "action.palette.vscodeServeWebStop", defaultValue: "Stop VS Code Inline Server", bundle: .module),
                keywords: ["vscode", "editor", "server"], category: .browser, symbol: "stop.fill", surfaces: [.palette],
                targets: [.pane], cliName: "browser stop-vs-code-inline-server"
            ),
            ActionDescriptor(
                id: "palette.vscodeServeWebRestart",
                title: String(localized: "action.palette.vscodeServeWebRestart", defaultValue: "Restart VS Code Inline Server", bundle: .module),
                keywords: ["vscode", "editor", "server"], category: .browser, symbol: "arrow.clockwise.circle",
                surfaces: [.palette], targets: [.pane], cliName: "browser restart-vs-code-inline-server"
            ),
        ]
    }
}
