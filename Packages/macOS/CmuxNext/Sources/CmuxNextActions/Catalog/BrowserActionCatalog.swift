// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum BrowserActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "browserBack",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserBack") + "\u{E002}" + String(localized: "action.browserBack", defaultValue: "Back", bundle: .module)),
                keywords: ["browser", "history"], defaultShortcut: Shortcut("[", modifiers: [.command]),
                category: .browser, symbol: "chevron.backward", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser back", mainMenu: .view
            ),
            ActionDescriptor(
                id: "browserForward",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserForward") + "\u{E002}" + String(localized: "action.browserForward", defaultValue: "Forward", bundle: .module)),
                keywords: ["browser", "history"], defaultShortcut: Shortcut("]", modifiers: [.command]),
                category: .browser, symbol: "chevron.forward", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser forward", mainMenu: .view
            ),
            ActionDescriptor(
                id: "browserReload",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserReload") + "\u{E002}" + String(localized: "action.browserReload", defaultValue: "Reload Page", bundle: .module)),
                keywords: ["browser", "refresh"], defaultShortcut: Shortcut("r", modifiers: [.command]),
                category: .browser, symbol: "arrow.clockwise", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser reload-page", mainMenu: .view
            ),
            ActionDescriptor(
                id: "browserHardReload",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserHardReload") + "\u{E002}" + String(localized: "action.browserHardReload", defaultValue: "Hard Reload Page", bundle: .module)),
                keywords: ["browser", "refresh", "cache"],
                defaultShortcut: Shortcut("r", modifiers: [.command, .shift]), category: .browser,
                symbol: "arrow.clockwise.circle", surfaces: [.palette, .keyboard, .menu], requires: [.browserFocused],
                targets: [.pane], cliName: "browser hard-reload-page", mainMenu: .view
            ),
            ActionDescriptor(
                id: "browser.openInChromium",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browser.openInChromium") + "\u{E002}" + String(localized: "action.browser.openInChromium", defaultValue: "Open in Chromium", bundle: .module)),
                keywords: ["browser", "engine", "chrome", "chromium", "cef", "switch"],
                category: .browser, symbol: "arrow.up.right.square", surfaces: [.palette, .contextMenu], requires: [.browserFocused],
                targets: [.tab], cliName: "browser open-in-chromium"
            ),
            ActionDescriptor(
                id: "browser.openInWebKit",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browser.openInWebKit") + "\u{E002}" + String(localized: "action.browser.openInWebKit", defaultValue: "Open in WebKit", bundle: .module)),
                keywords: ["browser", "engine", "safari", "webkit", "switch"],
                category: .browser, symbol: "safari", surfaces: [.palette, .contextMenu], requires: [.browserFocused],
                targets: [.tab], cliName: "browser open-in-webkit"
            ),
            ActionDescriptor(
                id: "focusBrowserAddressBar",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.focusBrowserAddressBar") + "\u{E002}" + String(localized: "action.focusBrowserAddressBar", defaultValue: "Focus Address Bar", bundle: .module)),
                keywords: ["browser", "url", "omnibox"],
                category: .browser, symbol: "link.circle", surfaces: [.palette, .keyboard], requires: [.browserFocused],
                targets: [.pane], cliName: "browser focus-address-bar"
            ),
            // Chrome's Search the Web (IDC_FOCUS_SEARCH, Opt-Cmd-F on the Mac): the
            // address bar in a search with the default engine. No default key:
            // Opt-Cmd-F stays Search All Windows (a default moves only with the
            // user's OK); bind one in cmux.json or run it from the palette.
            ActionDescriptor(
                id: "browser.focusSearch",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browser.focusSearch") + "\u{E002}" + String(localized: "action.browser.focusSearch", defaultValue: "Search the Web", bundle: .module)),
                keywords: ["browser", "search", "omnibox", "address bar", "google", "engine"],
                category: .browser, symbol: "magnifyingglass.circle", surfaces: [.palette, .keyboard], requires: [.browserFocused],
                targets: [.pane], cliName: "browser focus-search"
            ),
            ActionDescriptor(
                id: "browserZoomIn",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserZoomIn") + "\u{E002}" + String(localized: "action.browserZoomIn", defaultValue: "Zoom In", bundle: .module)),
                keywords: ["browser", "zoom"], defaultShortcut: Shortcut("=", modifiers: [.command]),
                category: .browser, symbol: "plus.magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser zoom-in", mainMenu: .view
            ),
            ActionDescriptor(
                id: "browserZoomOut",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserZoomOut") + "\u{E002}" + String(localized: "action.browserZoomOut", defaultValue: "Zoom Out", bundle: .module)),
                keywords: ["browser", "zoom"], defaultShortcut: Shortcut("-", modifiers: [.command]),
                category: .browser, symbol: "minus.magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser zoom-out", mainMenu: .view
            ),
            ActionDescriptor(
                id: "browserZoomReset",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserZoomReset") + "\u{E002}" + String(localized: "action.browserZoomReset", defaultValue: "Actual Size", bundle: .module)),
                keywords: ["browser", "zoom", "reset"], defaultShortcut: Shortcut("0", modifiers: [.command]),
                category: .browser, symbol: "1.magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser actual-size", mainMenu: .view
            ),
            ActionDescriptor(
                id: "markdownZoomIn",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.markdownZoomIn") + "\u{E002}" + String(localized: "action.markdownZoomIn", defaultValue: "Markdown: Zoom In", bundle: .module)),
                keywords: ["markdown", "zoom"], defaultShortcut: Shortcut("=", modifiers: [.command]),
                category: .browser, symbol: "plus.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.markdownFocused], targets: [.pane], cliName: "browser markdown-zoom-in"
            ),
            ActionDescriptor(
                id: "markdownZoomOut",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.markdownZoomOut") + "\u{E002}" + String(localized: "action.markdownZoomOut", defaultValue: "Markdown: Zoom Out", bundle: .module)),
                keywords: ["markdown", "zoom"], defaultShortcut: Shortcut("-", modifiers: [.command]),
                category: .browser, symbol: "minus.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.markdownFocused], targets: [.pane], cliName: "browser markdown-zoom-out"
            ),
            ActionDescriptor(
                id: "markdownZoomReset",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.markdownZoomReset") + "\u{E002}" + String(localized: "action.markdownZoomReset", defaultValue: "Markdown: Actual Size", bundle: .module)),
                keywords: ["markdown", "zoom", "reset"], defaultShortcut: Shortcut("0", modifiers: [.command]),
                category: .browser, symbol: "1.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.markdownFocused], targets: [.pane], cliName: "browser markdown-actual-size"
            ),
            ActionDescriptor(
                id: "toggleBrowserDeveloperTools",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.toggleBrowserDeveloperTools") + "\u{E002}" + String(localized: "action.toggleBrowserDeveloperTools", defaultValue: "Toggle Developer Tools", bundle: .module)),
                keywords: ["browser", "devtools", "inspector", "web inspector", "debug", "web view"],
                defaultShortcut: Shortcut("i", modifiers: [.option, .command]), category: .browser, symbol: "hammer",
                surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "browser toggle-developer-tools", mainMenu: .view
            ),
            ActionDescriptor(
                id: "showBrowserJavaScriptConsole",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.showBrowserJavaScriptConsole") + "\u{E002}" + String(localized: "action.showBrowserJavaScriptConsole", defaultValue: "Show JavaScript Console", bundle: .module)),
                keywords: ["browser", "devtools", "console"],
                defaultShortcut: Shortcut("j", modifiers: [.option, .command]), category: .browser, symbol: "terminal",
                surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "browser show-javascript-console", mainMenu: .view
            ),
            ActionDescriptor(
                id: "inspectBrowserElement",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.inspectBrowserElement") + "\u{E002}" + String(localized: "action.inspectBrowserElement", defaultValue: "Inspect Element", bundle: .module)),
                keywords: ["browser", "devtools", "inspector", "element", "picker", "web inspector", "debug", "web view"],
                defaultShortcut: Shortcut("c", modifiers: [.option, .command]), category: .browser, symbol: "cursorarrow.rays",
                surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "browser inspect-element", mainMenu: .view
            ),
            ActionDescriptor(
                id: "toggleBrowserFocusMode",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.toggleBrowserFocusMode") + "\u{E002}" + String(localized: "action.toggleBrowserFocusMode", defaultValue: "Toggle Browser Focus Mode", bundle: .module)),
                keywords: ["browser", "distraction"],
                defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: [.option, .command]), category: .browser,
                symbol: "eye", surfaces: [.palette, .keyboard, .menu, .contextMenu], requires: [.browserFocused],
                targets: [.pane], cliName: "browser toggle-focus-mode", mainMenu: .view
            ),
            {
                var designMode = ActionDescriptor(
                    id: "toggleBrowserDesignMode",
                    title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.toggleBrowserDesignMode") + "\u{E002}" + String(localized: "action.toggleBrowserDesignMode", defaultValue: "Toggle Browser Design Mode", bundle: .module)),
                    keywords: ["browser", "edit"], defaultShortcut: Shortcut("d", modifiers: [.control, .option, .command]),
                    category: .browser, symbol: "paintbrush.pointed", surfaces: [.keyboard, .menu],
                    requires: [.browserFocused], targets: [.pane], cliName: "browser toggle-design-mode", mainMenu: .view
                )
                // Design mode snapshots selected page pixels into a composer. Keep that raw capture
                // on the in-app person path until it shares the browser host's secret masker.
                designMode.isPersonOnly = true
                return designMode
            }(),
            ActionDescriptor(
                id: "toggleReactGrab",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.toggleReactGrab") + "\u{E002}" + String(localized: "action.toggleReactGrab", defaultValue: "Toggle React Grab", bundle: .module)),
                // No default chord: Shift-Cmd-G is Find Previous in a browser (R88).
                // The page's menu offers it next to Design Mode (Options).
                keywords: ["browser", "react", "inspect"], category: .browser,
                symbol: "hand.point.up.left", surfaces: [.palette, .keyboard, .menu], requires: [.browserFocused],
                targets: [.pane], cliName: "browser toggle-react-grab", mainMenu: .view
            ),
            // Single letters in a Chromium page with no text field focused
            // (the page saw the key first): label the links on screen.
            ActionDescriptor(
                id: "browserLinkHints",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserLinkHints") + "\u{E002}" + String(localized: "action.browserLinkHints", defaultValue: "Open Link by Hint", bundle: .module)),
                keywords: ["browser", "link", "hint", "vimium", "keyboard", "click"], defaultShortcut: Shortcut("f", modifiers: []),
                category: .browser, symbol: "character.cursor.ibeam", surfaces: [.palette, .keyboard],
                requires: [.browserFocused], targets: [.pane], cliName: "browser link-hints"
            ),
            ActionDescriptor(
                id: "browserLinkHintsNewSplit",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserLinkHintsNewSplit") + "\u{E002}" + String(localized: "action.browserLinkHintsNewSplit", defaultValue: "Open Link by Hint in New Split", bundle: .module)),
                keywords: ["browser", "link", "hint", "vimium", "keyboard", "split"], defaultShortcut: Shortcut("f", modifiers: [.shift]),
                category: .browser, symbol: "rectangle.righthalf.inset.filled", surfaces: [.palette, .keyboard],
                requires: [.browserFocused], targets: [.pane], cliName: "browser link-hints-split"
            ),
            // Opt-Cmd-X / Opt-Shift-Cmd-X: not Opt-Cmd-D, macOS's Dock hiding (system hot key 52, on by
            // default), which takes it before cmux (MacOSSystemShortcutsTests, PaneCreateKeySetTests).
            ActionDescriptor(
                id: "splitBrowserRight",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.splitBrowserRight") + "\u{E002}" + String(localized: "action.splitBrowserRight", defaultValue: "Split Browser Right", bundle: .module)),
                keywords: ["browser", "split"], defaultShortcut: Shortcut("x", modifiers: [.option, .command]),
                category: .browser, symbol: "rectangle.righthalf.inset.filled", surfaces: [.palette, .keyboard, .menu],
                targets: [.pane], cliName: "browser split-right", mainMenu: .view
            ),
            ActionDescriptor(
                id: "splitBrowserDown",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.splitBrowserDown") + "\u{E002}" + String(localized: "action.splitBrowserDown", defaultValue: "Split Browser Down", bundle: .module)),
                keywords: ["browser", "split"], defaultShortcut: Shortcut("x", modifiers: [.shift, .option, .command]),
                category: .browser, symbol: "rectangle.bottomhalf.inset.filled", surfaces: [.palette, .keyboard, .menu],
                targets: [.pane], cliName: "browser split-down", mainMenu: .view
            ),
            ActionDescriptor(
                id: "palette.browserOpenDefault",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.browserOpenDefault") + "\u{E002}" + String(localized: "action.palette.browserOpenDefault", defaultValue: "Open in Default Browser", bundle: .module)),
                keywords: ["browser", "external"], category: .browser, symbol: "safari", surfaces: [.palette, .menu],
                requires: [.browserFocused], targets: [.pane], cliName: "browser open-in-default", mainMenu: .view
            ),
            ActionDescriptor(
                id: "palette.browserToggleOmnibar",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.browserToggleOmnibar") + "\u{E002}" + String(localized: "action.palette.browserToggleOmnibar", defaultValue: "Toggle Omnibar", bundle: .module)),
                keywords: ["browser", "address bar"], category: .browser, symbol: "rectangle.topthird.inset.filled",
                surfaces: [.palette], requires: [.browserFocused], targets: [.pane], cliName: "browser toggle-omnibar"
            ),
            ActionDescriptor(
                id: "palette.browserClearHistory",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.browserClearHistory") + "\u{E002}" + String(localized: "action.palette.browserClearHistory", defaultValue: "Clear Browser History…", bundle: .module)),
                keywords: ["browser", "privacy", "clear", "delete"], category: .browser, symbol: "clock.badge.xmark", surfaces: [.palette],
                arguments: [HistoryActionCatalog.historyRange, CatalogArgument.browserProfile],
                targets: [.pane], cliName: "browser clear-history", destructive: true
            ),
            {
                // Person-only and no CLI verb (PASSWORDS-IMPORT-ANY-BROWSER): an agent must not put
                // the import and its password consent screen in front of the person, who would be
                // asked to approve something they did not start. Palette, File menu, the browser
                // context menus, the Passwords page and onboarding open it.
                var importFromBrowser = ActionDescriptor(
                    id: "importFromBrowser",
                    title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.importFromBrowser2") + "\u{E002}" + String(localized: "action.importFromBrowser2", defaultValue: "Import from Browser…", bundle: .module)),
                    keywords: ["browser", "bookmarks", "cookies", "passwords", "chrome", "arc", "edge", "brave", "firefox", "safari"],
                    category: .browser, symbol: "square.and.arrow.down.on.square", surfaces: [.palette, .menu, .contextMenu],
                    targets: [.pane], mainMenu: .file
                )
                importFromBrowser.isPersonOnly = true
                return importFromBrowser
            }(),
            {
                var importCSV = ActionDescriptor(
                    id: "password.importCSV",
                    title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.password.importCSV") + "\u{E002}" + String(localized: "action.password.importCSV", defaultValue: "Import Passwords from CSV…", bundle: .module)),
                    keywords: ["passwords", "import", "csv", "chrome", "edge", "safari", "firefox", "1password", "bitwarden"],
                    category: .browser, symbol: "key", surfaces: [.palette, .keyboard, .menu], mainMenu: .file
                )
                // An agent must not be able to put the file picker in front of the person.
                importCSV.isPersonOnly = true
                return importCSV
            }(),
            {
                // The Passwords page (passwords.md 1.4). Person-only and no CLI verb or MCP tool:
                // the page shows sites and usernames, which agents never see (decision P2).
                var open = ActionDescriptor(
                    id: "passwords.open",
                    title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.passwords.open") + "\u{E002}" + String(localized: "action.passwords.open", defaultValue: "Passwords", bundle: .module)),
                    keywords: ["passwords", "passkeys", "sign-in", "logins", "credentials", "keychain", "autofill"],
                    category: .browser, symbol: "key", surfaces: [.palette],
                    surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
                )
                open.isPersonOnly = true
                return open
            }(),
            ActionDescriptor(
                id: "palette.enableBrowser",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.enableBrowser") + "\u{E002}" + String(localized: "action.palette.enableBrowser", defaultValue: "Enable cmux Browser", bundle: .module)),
                keywords: ["browser", "enable"], category: .browser, symbol: "globe", surfaces: [.palette],
                targets: [.pane], cliName: "browser enable"
            ),
            ActionDescriptor(
                id: "palette.disableBrowser",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.disableBrowser") + "\u{E002}" + String(localized: "action.palette.disableBrowser", defaultValue: "Disable cmux Browser", bundle: .module)),
                keywords: ["browser", "disable"], category: .browser, symbol: "globe.badge.chevron.backward",
                surfaces: [.palette], targets: [.pane], cliName: "browser disable"
            ),
            ActionDescriptor(
                id: "openLinkInDefaultBrowser",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.openLinkInDefaultBrowser") + "\u{E002}" + String(localized: "action.openLinkInDefaultBrowser", defaultValue: "Open Link in Default Browser", bundle: .module)),
                keywords: ["browser", "link", "external"], category: .browser, symbol: "arrow.up.forward.app",
                surfaces: [.contextMenu], arguments: [BrowserHitActionCatalog.linkURL], targets: [.tab],
                cliName: "browser open-link-in-default",
                // The page's and the terminal's link rows (cx-k9go); left out while cmux is the default browser.
                surfacePlan: ActionSurfacePlan(contextMenus: [ActionSurfaceCatalog.p(.browserLink, .navigate, 5)])
            ),
            // No shortcut: Cmd-P stays Go to Workspace (plans/cmux-next/browser-parity.md, D4).
            ActionDescriptor(
                id: "browserPrint",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserPrint") + "\u{E002}" + String(localized: "action.browserPrint", defaultValue: "Print…", bundle: .module)),
                keywords: ["browser", "print", "page", "pdf"], category: .browser, symbol: "printer",
                surfaces: [.palette, .menu, .contextMenu], requires: [.browserFocused], targets: [.pane], mainMenu: .file
            ),
            {
                var screenshot = ActionDescriptor(
                    id: "browserScreenshotPage",
                    title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserScreenshotPage") + "\u{E002}" + String(localized: "action.browserScreenshotPage", defaultValue: "Screenshot Page", bundle: .module)),
                    keywords: ["browser", "capture"], category: .browser, symbol: "camera", surfaces: [.contextMenu],
                    requires: [.browserFocused], targets: [.pane], cliName: "browser screenshot-page"
                )
                screenshot.isPersonOnly = true
                return screenshot
            }(),
            {
                var screenshot = ActionDescriptor(
                    id: "browserScreenshotSection",
                    title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserScreenshotSection") + "\u{E002}" + String(localized: "action.browserScreenshotSection", defaultValue: "Screenshot Section", bundle: .module)),
                    keywords: ["browser", "capture"], category: .browser, symbol: "camera.viewfinder",
                    surfaces: [.contextMenu], requires: [.browserFocused], targets: [.pane],
                    cliName: "browser screenshot-section"
                )
                screenshot.isPersonOnly = true
                return screenshot
            }(),
            ActionDescriptor(
                id: "browserTheme",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserTheme") + "\u{E002}" + String(localized: "action.browserTheme", defaultValue: "Browser Theme…", bundle: .module)),
                keywords: ["browser", "appearance", "dark"], category: .browser, symbol: "circle.righthalf.filled",
                surfaces: [.contextMenu], requires: [.browserFocused], arguments: [CatalogArgument.themeChoice],
                targets: [.pane], cliName: "browser theme"
            ),
            ActionDescriptor(
                id: "saveFilePreview",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.saveFilePreview") + "\u{E002}" + String(localized: "action.saveFilePreview", defaultValue: "Save File", bundle: .module)),
                keywords: ["file", "editor"], defaultShortcut: Shortcut("s", modifiers: [.command]), category: .browser,
                symbol: "square.and.arrow.down", surfaces: [.keyboard, .menu], requires: [.codeEditorFocused],
                targets: [.pane], cliName: "browser save-file", mainMenu: .view
            ),
            ActionDescriptor(
                id: "toggleFileEditorWordWrap",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.toggleFileEditorWordWrap") + "\u{E002}" + String(localized: "action.toggleFileEditorWordWrap", defaultValue: "Toggle Word Wrap", bundle: .module)),
                keywords: ["file", "editor", "wrap"], defaultShortcut: Shortcut("z", modifiers: [.option]),
                category: .browser, symbol: "text.word.spacing", surfaces: [.keyboard], requires: [.codeEditorFocused],
                targets: [.pane], cliName: "browser toggle-word-wrap"
            ),
            // The Monaco editor's minimap (`editor.minimap.enabled`), as VS Code's Toggle Minimap; the
            // page toolbar's Minimap button writes the same setting. No default key: a default needs a design call.
            ActionDescriptor(
                id: "toggleFileEditorMinimap",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.toggleFileEditorMinimap") + "\u{E002}" + String(localized: "action.toggleFileEditorMinimap", defaultValue: "Toggle Editor Minimap", bundle: .module)),
                keywords: ["file", "editor", "code", "minimap", "overview", "vscode", "monaco"],
                category: .browser, symbol: "sidebar.squares.right", surfaces: [.keyboard], requires: [.codeEditorFocused],
                targets: [.pane], cliName: "browser toggle-minimap"
            ),
            ActionDescriptor(
                id: "filePreviewOpenWith",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.filePreviewOpenWith") + "\u{E002}" + String(localized: "action.filePreviewOpenWith", defaultValue: "Open File With…", bundle: .module)),
                keywords: ["file", "open in"], category: .browser, symbol: "arrow.up.forward.app",
                surfaces: [.contextMenu], requires: [.filePreviewFocused], arguments: [CatalogArgument.appString],
                targets: [.pane], cliName: "browser open-file-with"
            ),
            ActionDescriptor(
                id: "filePreviewOpenExternally",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.filePreviewOpenExternally") + "\u{E002}" + String(localized: "action.filePreviewOpenExternally", defaultValue: "Open File Externally", bundle: .module)),
                keywords: ["file", "external"], category: .browser, symbol: "arrow.up.right.square",
                surfaces: [.contextMenu], requires: [.filePreviewFocused], targets: [.pane],
                cliName: "browser open-file-externally"
            ),
            ActionDescriptor(
                id: "filePreviewRevealInFinder",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.filePreviewRevealInFinder") + "\u{E002}" + String(localized: "action.filePreviewRevealInFinder", defaultValue: "Reveal File in Finder", bundle: .module)),
                keywords: ["file", "finder"], category: .browser, symbol: "folder", surfaces: [.contextMenu],
                requires: [.filePreviewFocused], targets: [.pane], cliName: "browser reveal-file-in-finder"
            ),
            ActionDescriptor(
                id: "filePreviewRevealInFiles",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.filePreviewRevealInFiles") + "\u{E002}" + String(localized: "action.filePreviewRevealInFiles", defaultValue: "Reveal File in cmux Files", bundle: .module)),
                keywords: ["file", "files", "finder", "reveal", "folder"], category: .browser, symbol: "folder",
                surfaces: [.contextMenu], requires: [.filePreviewFocused], targets: [.pane],
                cliName: "browser reveal-file-in-files"
            ),
            ActionDescriptor(
                id: "diffViewerNextLine",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.diffViewerNextLine") + "\u{E002}" + String(localized: "action.diffViewerNextLine", defaultValue: "Diff: Next Line", bundle: .module)),
                keywords: ["diff", "vim"], defaultShortcut: Shortcut("j", modifiers: []), category: .browser,
                symbol: "arrow.down", surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-next-line"
            ),
            ActionDescriptor(
                id: "diffViewerPreviousLine",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.diffViewerPreviousLine") + "\u{E002}" + String(localized: "action.diffViewerPreviousLine", defaultValue: "Diff: Previous Line", bundle: .module)),
                keywords: ["diff", "vim"], defaultShortcut: Shortcut("k", modifiers: []), category: .browser,
                symbol: "arrow.up", surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-previous-line"
            ),
            ActionDescriptor(
                id: "diffViewerHalfPageDown",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.diffViewerHalfPageDown") + "\u{E002}" + String(localized: "action.diffViewerHalfPageDown", defaultValue: "Diff: Half Page Down", bundle: .module)),
                keywords: ["diff", "vim", "scroll"], defaultShortcut: Shortcut("d", modifiers: [.control]),
                category: .browser, symbol: "arrow.down.to.line", surfaces: [.keyboard], requires: [.diffViewerFocused],
                targets: [.pane], cliName: "browser diff-half-page-down"
            ),
            ActionDescriptor(
                id: "diffViewerHalfPageUp",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.diffViewerHalfPageUp") + "\u{E002}" + String(localized: "action.diffViewerHalfPageUp", defaultValue: "Diff: Half Page Up", bundle: .module)),
                keywords: ["diff", "vim", "scroll"], defaultShortcut: Shortcut("u", modifiers: [.control]),
                category: .browser, symbol: "arrow.up.to.line", surfaces: [.keyboard], requires: [.diffViewerFocused],
                targets: [.pane], cliName: "browser diff-half-page-up"
            ),
            ActionDescriptor(
                id: "diffViewerNextHunk",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.diffViewerNextHunk") + "\u{E002}" + String(localized: "action.diffViewerNextHunk", defaultValue: "Diff: Next Hunk", bundle: .module)),
                keywords: ["diff", "vim"], defaultShortcut: Shortcut("n", modifiers: [.control]), category: .browser,
                symbol: "chevron.down.2", surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-next-hunk"
            ),
            ActionDescriptor(
                id: "diffViewerPreviousHunk",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.diffViewerPreviousHunk") + "\u{E002}" + String(localized: "action.diffViewerPreviousHunk", defaultValue: "Diff: Previous Hunk", bundle: .module)),
                keywords: ["diff", "vim"], defaultShortcut: Shortcut("p", modifiers: [.control]), category: .browser,
                symbol: "chevron.up.2", surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-previous-hunk"
            ),
            ActionDescriptor(
                id: "diffViewerGoToBottom",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.diffViewerGoToBottom") + "\u{E002}" + String(localized: "action.diffViewerGoToBottom", defaultValue: "Diff: Go to Bottom", bundle: .module)),
                keywords: ["diff", "vim", "end"], defaultShortcut: Shortcut("g", modifiers: [.shift]),
                shortcutLabel: "G", category: .browser, symbol: "arrow.down.to.line.alt", surfaces: [.keyboard],
                requires: [.diffViewerFocused], targets: [.pane], cliName: "browser diff-go-to-bottom"
            ),
            ActionDescriptor(
                id: "diffViewerGoToTop",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.diffViewerGoToTop") + "\u{E002}" + String(localized: "action.diffViewerGoToTop", defaultValue: "Diff: Go to Top", bundle: .module)),
                keywords: ["diff", "vim", "start"], shortcutLabel: "g g", category: .browser,
                symbol: "arrow.up.to.line.alt", surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-go-to-top"
            ),
            ActionDescriptor(
                id: "diffViewerSearch",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.diffViewerSearch") + "\u{E002}" + String(localized: "action.diffViewerSearch", defaultValue: "Diff: Search", bundle: .module)),
                keywords: ["diff", "vim", "find"], defaultShortcut: Shortcut("/", modifiers: []), category: .browser,
                symbol: "magnifyingglass", surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-search"
            ),
            ActionDescriptor(
                id: "diffViewerNextFile",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.diffViewerNextFile") + "\u{E002}" + String(localized: "action.diffViewerNextFile", defaultValue: "Diff: Next File", bundle: .module)),
                keywords: ["diff", "vim"], shortcutLabel: "] f", category: .browser, symbol: "doc.badge.arrow.up",
                surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-next-file"
            ),
            ActionDescriptor(
                id: "diffViewerPreviousFile",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.diffViewerPreviousFile") + "\u{E002}" + String(localized: "action.diffViewerPreviousFile", defaultValue: "Diff: Previous File", bundle: .module)),
                keywords: ["diff", "vim"], shortcutLabel: "[ f", category: .browser, symbol: "doc.badge.clock",
                surfaces: [.keyboard], requires: [.diffViewerFocused], targets: [.pane],
                cliName: "browser diff-previous-file"
            ),
            // Chrome's device toolbar devices (cx-ocbf3): the daemon's list
            // (browser.devices.list) and the tab's emulation (browser.tab.emulate).
            ActionDescriptor(
                id: "browserDevice",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserDevice") + "\u{E002}" + String(localized: "action.browserDevice", defaultValue: "Emulate Device…", bundle: .module)),
                keywords: ["browser", "device", "responsive", "mobile", "viewport", "emulation", "iphone", "android", "toolbar"],
                category: .browser, symbol: "iphone", surfaces: [.palette, .contextMenu], requires: [.browserFocused],
                arguments: [CatalogArgument.deviceString, CatalogArgument.orientationString], targets: [.pane],
                cliName: "browser device"
            ),
            // Fit as 16:9 Desktop (cx-va1wd): a toggle of the tab's emulation
            // (browser.tab.emulate {fit: "16:9"}); a desktop layout scaled to
            // the pane's width that fills its full height.
            ActionDescriptor(
                id: "browserFitDesktop",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserFitDesktop") + "\u{E002}" + String(localized: "action.browserFitDesktop", defaultValue: "Fit as 16:9 Desktop", bundle: .module)),
                keywords: ["browser", "fit", "16:9", "16x9", "desktop", "scale", "zoom out", "viewport", "emulation", "split", "narrow"],
                category: .browser, symbol: "rectangle.ratio.16.to.9", surfaces: [.palette, .contextMenu], requires: [.browserFocused],
                targets: [.pane], cliName: "browser fit-desktop"
            ),
            // Fit (cx-qby5j): any fit by value (an aspect ratio at the pane's height, or a fixed
            // width), or off; the context menu lists the common ones with the current one checked.
            ActionDescriptor(
                id: "browserFit",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserFit") + "\u{E002}" + String(localized: "action.browserFit", defaultValue: "Fit as Desktop…", bundle: .module)),
                keywords: ["browser", "fit", "desktop", "aspect", "ratio", "16:9", "16:10", "4:3", "21:9", "1280", "1440", "1920", "width", "scale", "viewport"],
                category: .browser, symbol: "rectangle.dashed", surfaces: [.palette, .contextMenu], requires: [.browserFocused],
                arguments: [CatalogArgument.fitChoice], targets: [.pane], cliName: "browser fit"
            ),
            // Fit as Desktop (1280) (cx-2ftlq): the same toggle with a fixed 1280 CSS px layout
            // width (browser.tab.emulate {fit: "1280"}); only one fit is on a tab at a time.
            ActionDescriptor(
                id: "browserFitDesktop1280",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.browserFitDesktop1280") + "\u{E002}" + String(localized: "action.browserFitDesktop1280", defaultValue: "Fit as Desktop (1280)", bundle: .module)),
                keywords: ["browser", "fit", "1280", "desktop", "scale", "zoom out", "viewport", "emulation", "split", "narrow"],
                category: .browser, symbol: "desktopcomputer", surfaces: [.palette, .contextMenu], requires: [.browserFocused],
                targets: [.pane], cliName: "browser fit-desktop-1280"
            ),
        ] + vscodeServerDescriptors() + agentGuardDescriptors() + importFilesDescriptors() + importCookiesDescriptors() + cookieBannerDescriptors() + pinnedPageDescriptors() + editSourceDescriptors()
            + devToolsDescriptors()
    }
}
