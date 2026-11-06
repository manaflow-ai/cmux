// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum WindowActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "openSettings",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.openSettings") + "\u{E002}" + String(localized: "action.openSettings", defaultValue: "Settings…", bundle: .module)),
                keywords: ["preferences", "options", "config"], defaultShortcut: Shortcut(",", modifiers: [.command]),
                category: .window, symbol: "gearshape", surfaces: [.palette, .keyboard, .menu],
                arguments: [CatalogArgument.settingsSectionChoice, CatalogArgument.settingString.optional], cliName: "app settings",
                mainMenu: .app
            ),
            ActionDescriptor(
                id: "newWindow",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.newWindow") + "\u{E002}" + String(localized: "action.newWindow", defaultValue: "New Window", bundle: .module)),
                keywords: ["open"], defaultShortcut: Shortcut("n", modifiers: [.command, .shift]), category: .window,
                symbol: "macwindow.badge.plus", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                cliName: "app new-window", mainMenu: .window
            ),
            // Incognito window (user decisions 2026-09-30, 2026-10-07):
            // palette, CLI, menu and Option-Shift-Cmd-N (Shift-Cmd-N is New
            // Window, also in a page).
            ActionDescriptor(
                id: "newIncognitoWindow",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.newIncognitoWindow") + "\u{E002}" + String(localized: "action.newIncognitoWindow", defaultValue: "New Incognito Window", bundle: .module)),
                keywords: ["private", "incognito", "browser", "off the record"],
                defaultShortcut: Shortcut("n", modifiers: [.command, .option, .shift]), category: .window,
                symbol: "eyeglasses", surfaces: [.palette, .keyboard, .menu],
                cliName: "app new-incognito-window", mainMenu: .window
            ),
            ActionDescriptor(
                id: "closeWindow",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.closeWindow") + "\u{E002}" + String(localized: "action.closeWindow", defaultValue: "Close Window", bundle: .module)),
                defaultShortcut: Shortcut("w", modifiers: [.control, .command]), category: .window,
                symbol: "xmark.rectangle", surfaces: [.palette, .keyboard, .menu], cliName: "app close-window", mainMenu: .file
            ),
            // Every other open window; each window's own close check runs (an
            // incognito window asks), and terminals keep running as for Close Window.
            ActionDescriptor(
                id: "window.closeOthers",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.window.closeOthers") + "\u{E002}" + String(localized: "action.window.closeOthers", defaultValue: "Close Other Windows", bundle: .module)),
                keywords: ["close", "windows", "other", "others"], category: .window, symbol: "xmark.rectangle.portrait",
                surfaces: [.palette, .menu], cliName: "app close-other-windows", mainMenu: .file
            ),
            // Merge All Windows (Leo 2026-10-29, as in Safari and Finder): every other normal window's
            // workspaces move into this one, each keeping its space, and those windows close.
            // Incognito windows stay apart (spaces-overhaul-DESIGN.md rule 2).
            ActionDescriptor(
                id: "window.mergeAll",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.window.mergeAll") + "\u{E002}" + String(localized: "action.window.mergeAll", defaultValue: "Merge All Windows", bundle: .module)),
                keywords: ["merge", "windows", "combine", "gather", "join", "spaces"], category: .window, symbol: "rectangle.stack",
                surfaces: [.palette, .menu], cliName: "app merge-all-windows", mainMenu: .window
            ),
            // Ghostty's close_all_windows, toggle_maximize and goto_window
            // route here (GHOSTTY-CONFIG item (c), coordinator A1, B1, E1).
            ActionDescriptor(
                id: "closeAllWindows",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.closeAllWindows") + "\u{E002}" + String(localized: "action.closeAllWindows", defaultValue: "Close All Windows", bundle: .module)),
                keywords: ["close", "windows", "all"], category: .window, symbol: "xmark.rectangle.portrait",
                surfaces: [.palette, .keyboard, .menu], cliName: "app close-all-windows", mainMenu: .file
            ),
            ActionDescriptor(
                id: "zoomWindow",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.zoomWindow") + "\u{E002}" + String(localized: "action.zoomWindow", defaultValue: "Zoom", bundle: .module)),
                keywords: ["maximize", "window", "resize", "fill"], category: .window, symbol: "arrow.up.left.and.arrow.down.right.square",
                surfaces: [.palette, .keyboard, .menu], cliName: "app zoom-window", mainMenu: .window
            ),
            ActionDescriptor(
                id: "selectNextWindow",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.selectNextWindow") + "\u{E002}" + String(localized: "action.selectNextWindow", defaultValue: "Select Next Window", bundle: .module)),
                keywords: ["cycle", "window", "switch"], category: .window, symbol: "macwindow.and.cursorarrow",
                surfaces: [.palette, .keyboard], cliName: "app select-next-window"
            ),
            ActionDescriptor(
                id: "selectPreviousWindow",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.selectPreviousWindow") + "\u{E002}" + String(localized: "action.selectPreviousWindow", defaultValue: "Select Previous Window", bundle: .module)),
                keywords: ["cycle", "window", "switch"], category: .window, symbol: "macwindow.and.cursorarrow",
                surfaces: [.palette, .keyboard], cliName: "app select-previous-window"
            ),
            ActionDescriptor(
                id: "minimizeWindow",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.minimizeWindow") + "\u{E002}" + String(localized: "action.minimizeWindow", defaultValue: "Minimize", bundle: .module)),
                keywords: ["dock", "hide", "miniaturize"], category: .window, symbol: "minus.rectangle",
                surfaces: [.palette], cliName: "app minimize-window"
            ),
            // A PNG of the window as on screen, never focusing or raising it (a person copies
            // it without Screen Recording; ScreenshotHandlers). An agent's or a script's
            // capture comes back with every browser page and agent chat masked.
            ActionDescriptor(
                id: "window.screenshot",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.window.screenshot") + "\u{E002}" + String(localized: "action.window.screenshot", defaultValue: "Screenshot Window", bundle: .module)),
                keywords: ["screenshot", "capture", "image", "png", "picture"], category: .window, symbol: "camera",
                surfaces: [.palette], arguments: [CatalogArgument.screenshotOut], targets: [.window],
                cliName: "window screenshot",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "toggleFullScreen",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.toggleFullScreen") + "\u{E002}" + String(localized: "action.toggleFullScreen", defaultValue: "Toggle Full Screen", bundle: .module)),
                keywords: ["fullscreen", "maximize"], defaultShortcut: Shortcut("f", modifiers: [.control, .command]),
                category: .window, symbol: "arrow.up.left.and.arrow.down.right", surfaces: [.palette, .keyboard, .menu],
                cliName: "app toggle-full-screen", mainMenu: .window
            ),
            // Quit and the local terminals (user decision 2026-09-30): the
            // terminals run in cmux-tui and outlive the app. Quit asks while
            // local terminals exist (setting `app.quitBehavior`); a scripted
            // run never asks and takes `--keep-sessions`, `--end-sessions` (keeps
            // the layout) or `--end-everything`.
            ActionDescriptor(
                id: "quit", title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.quit") + "\u{E002}" + String(localized: "action.quit", defaultValue: "Quit cmux", bundle: .module)),
                keywords: ["exit", "close"], defaultShortcut: Shortcut("q", modifiers: [.command]), category: .window,
                symbol: "power", surfaces: [.keyboard, .menu],
                arguments: [
                    ActionArgument(name: "keepSessions",
                                   title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.keepSessions") + "\u{E002}" + String(localized: "argument.keepSessions", defaultValue: "Keep Sessions Running", bundle: .module)),
                                   kind: .bool, isRequired: false),
                    ActionArgument(name: "endSessions",
                                   title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.endSessionsKeepLayout") + "\u{E002}" + String(localized: "argument.endSessionsKeepLayout", defaultValue: "End Sessions, Keep Layout", bundle: .module)),
                                   kind: .bool, isRequired: false),
                    ActionArgument(name: "endEverything",
                                   title: ("\u{E000}Localizable\u{E001}" + String(describing: "argument.endEverything") + "\u{E002}" + String(localized: "argument.endEverything", defaultValue: "End Everything", bundle: .module)),
                                   kind: .bool, isRequired: false),
                ],
                cliName: "app quit", mainMenu: .app
            ),
            ActionDescriptor(
                id: "quitKeepSessions",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.quitKeepSessions") + "\u{E002}" + String(localized: "action.quitKeepSessions", defaultValue: "Quit and Keep Sessions", bundle: .module)),
                keywords: ["exit", "close", "background", "terminals", "cmux-tui", "detach"], category: .window,
                symbol: "power", surfaces: [.palette, .menu], cliName: "app quit-keep-sessions", mainMenu: .app
            ),
            ActionDescriptor(
                id: "quitEndSessions",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.quitEndSessionsKeepLayout") + "\u{E002}" + String(localized: "action.quitEndSessionsKeepLayout", defaultValue: "Quit and End Sessions, Keep Layout", bundle: .module)),
                keywords: ["exit", "close", "kill", "terminals", "cmux-tui", "stop", "layout"], category: .window,
                symbol: "power", surfaces: [.palette, .menu], cliName: "app quit-end-sessions", mainMenu: .app
            ),
            ActionDescriptor(
                id: "quitEndEverything",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.quitEndEverything") + "\u{E002}" + String(localized: "action.quitEndEverything", defaultValue: "Quit and End Everything", bundle: .module)),
                keywords: ["exit", "close", "kill", "terminals", "cmux-tui", "stop", "workspaces", "fresh", "reset"], category: .window,
                symbol: "power", surfaces: [.palette, .menu], cliName: "app quit-end-everything", mainMenu: .app
            ),
            {
                var showHide = ActionDescriptor(
                    id: "showHideAllWindows",
                    title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.showHideAllWindows") + "\u{E002}" + String(localized: "action.showHideAllWindows", defaultValue: "Show/Hide All Windows", bundle: .module)),
                    keywords: ["global", "hotkey", "summon"],
                    defaultShortcut: Shortcut(".", modifiers: [.control, .option, .command]), category: .window,
                    symbol: "macwindow.on.rectangle", surfaces: [.keyboard], cliName: "app show-hide-all-windows"
                )
                // Summons cmux from any app, so the key works while cmux is in the background.
                showHide.isGlobalHotKey = true
                return showHide
            }(),
            ActionDescriptor(
                id: "globalSearch",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.globalSearch") + "\u{E002}" + String(localized: "action.globalSearch", defaultValue: "Search All Windows…", bundle: .module)),
                keywords: ["find", "global"], defaultShortcut: Shortcut("f", modifiers: [.option, .command]),
                category: .window, symbol: "magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                arguments: [CatalogArgument.textString.optional],
                cliName: "app search-all-windows", mainMenu: .window
            ),
            // Opens one palette scope (plans/cmux-next/palette-scopes.md):
            // `cmux palette open --arg scope=tabs --focus`. CLI and MCP runs
            // need focus (the palette takes the keyboard); agents read rows
            // with the `palette.query` socket method instead.
            ActionDescriptor(
                id: "palette.open",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.open") + "\u{E002}" + String(localized: "action.palette.open", defaultValue: "Open Palette Scope…", bundle: .module)),
                keywords: ["palette", "scope", "search in"], category: .window, symbol: "square.grid.2x2",
                surfaces: [.palette, .keyboard], arguments: [CatalogArgument.scopeString, CatalogArgument.queryString],
                cliName: "palette open", surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "commandPalette",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.commandPalette") + "\u{E002}" + String(localized: "action.commandPalette", defaultValue: "Command Palette…", bundle: .module)),
                keywords: ["actions", "commands", "search"],
                defaultShortcut: Shortcut("p", modifiers: [.command, .shift]), category: .window, symbol: "command",
                surfaces: [.keyboard, .menu], cliName: "app command-palette", mainMenu: .window
            ),
            ActionDescriptor(
                id: "commandPaletteNext",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.commandPaletteNext") + "\u{E002}" + String(localized: "action.commandPaletteNext", defaultValue: "Palette: Select Next Item", bundle: .module)),
                defaultShortcut: Shortcut("n", modifiers: [.control]), category: .window, symbol: "chevron.down",
                surfaces: [.keyboard], requires: [.paletteOpen], cliName: "app palette-select-next-item"
            ),
            ActionDescriptor(
                id: "commandPalettePrevious",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.commandPalettePrevious") + "\u{E002}" + String(localized: "action.commandPalettePrevious", defaultValue: "Palette: Select Previous Item", bundle: .module)),
                defaultShortcut: Shortcut("p", modifiers: [.control]), category: .window, symbol: "chevron.up",
                surfaces: [.keyboard], requires: [.paletteOpen], cliName: "app palette-select-previous-item"
            ),
            ActionDescriptor(
                id: "goToWorkspace",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.goToWorkspace") + "\u{E002}" + String(localized: "action.goToWorkspace", defaultValue: "Go to Workspace…", bundle: .module)),
                keywords: ["switch", "jump", "switcher"], defaultShortcut: Shortcut("p", modifiers: [.command]),
                category: .window, symbol: "arrow.right.square", surfaces: [.keyboard, .menu],
                arguments: [CatalogArgument.workspaceWorkspace], cliName: "app go-to-workspace", mainMenu: .window
            ),
            // Cmd-Shift-A: Search, everything in one list: open workspaces and tabs plus browser history,
            // agent chats, closed tabs and past commands (plans/cmux-next/search-everything-DESIGN.md
            // section 10.1). Cmd-P (`goToWorkspace`) lists only what is open. The id predates that
            // split; user key files name it, so it stays.
            ActionDescriptor(
                id: "search.chats",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.search.chats") + "\u{E002}" + String(localized: "action.search.chats", defaultValue: "Search Everything…", bundle: .module)),
                keywords: ["search", "everything", "history", "chats", "agents", "chief", "find", "acp"],
                defaultShortcut: Shortcut("a", modifiers: [.command, .shift]),
                category: .window, symbol: "magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                arguments: [CatalogArgument.queryString], cliName: "app search-chats", mainMenu: .window
            ),
            ActionDescriptor(
                id: "palette.openTaskManager",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.openTaskManager") + "\u{E002}" + String(localized: "action.palette.openTaskManager", defaultValue: "Task Manager", bundle: .module)),
                keywords: ["processes", "cpu", "memory", "activity"], category: .window,
                symbol: "gauge.with.dots.needle.33percent", surfaces: [.palette, .menu], cliName: "app task-manager",
                mainMenu: .window
            ),
            ActionDescriptor(
                id: "palette.sleepyMode",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.palette.sleepyMode") + "\u{E002}" + String(localized: "action.palette.sleepyMode", defaultValue: "Sleepy Mode", bundle: .module)),
                keywords: ["idle", "pause", "battery"], category: .window, symbol: "moon.zzz",
                surfaces: [.palette, .menu], cliName: "app sleepy-mode", mainMenu: .window
            ),
            ActionDescriptor(
                id: "keepMacAwake",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.keepMacAwake") + "\u{E002}" + String(localized: "action.keepMacAwake", defaultValue: "Keep Mac Awake", bundle: .module)),
                keywords: ["caffeinate", "sleep"], category: .window, symbol: "cup.and.saucer", surfaces: [.menu],
                cliName: "app keep-mac-awake", mainMenu: .app
            ),
            ActionDescriptor(
                id: "showMainWindow",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.showMainWindow") + "\u{E002}" + String(localized: "action.showMainWindow", defaultValue: "Show cmux", bundle: .module)),
                keywords: ["open", "window"], category: .window, symbol: "macwindow", surfaces: [.menu],
                cliName: "app show", mainMenu: .window
            ),
            ActionDescriptor(
                id: "about", title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.about") + "\u{E002}" + String(localized: "action.about", defaultValue: "About cmux", bundle: .module)),
                keywords: ["version"], category: .window, symbol: "info.circle", surfaces: [.menu],
                cliName: "app about", mainMenu: .app
            ),
            ActionDescriptor(
                id: "taskManager.killProcess",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.taskManager.killProcess") + "\u{E002}" + String(localized: "action.taskManager.killProcess", defaultValue: "Kill Process…", bundle: .module)),
                keywords: ["terminate", "signal"], category: .window, symbol: "xmark.octagon", surfaces: [.contextMenu],
                arguments: [CatalogArgument.processString], cliName: "app kill-process", destructive: true
            ),
        ]
    }
}
