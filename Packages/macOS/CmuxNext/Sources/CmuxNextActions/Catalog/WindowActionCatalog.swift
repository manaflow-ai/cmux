// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum WindowActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "openSettings",
                title: String(localized: "action.openSettings", defaultValue: "Settings…", bundle: .module),
                keywords: ["preferences", "options", "config"], defaultShortcut: Shortcut(",", modifiers: [.command]),
                category: .window, symbol: "gearshape", surfaces: [.palette, .keyboard, .menu],
                arguments: [CatalogArgument.settingsSectionChoice, CatalogArgument.settingString.optional], cliName: "app settings",
                mainMenu: .app
            ),
            ActionDescriptor(
                id: "newWindow",
                title: String(localized: "action.newWindow", defaultValue: "New Window", bundle: .module),
                keywords: ["open"], defaultShortcut: Shortcut("n", modifiers: [.command, .shift]), category: .window,
                symbol: "macwindow.badge.plus", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                cliName: "app new-window", mainMenu: .window
            ),
            // Incognito window (user decision 2026-09-30): palette, CLI,
            // menu and a bindable shortcut with no default (Cmd-Shift-N is
            // New Window).
            ActionDescriptor(
                id: "newIncognitoWindow",
                title: String(localized: "action.newIncognitoWindow", defaultValue: "New Incognito Window", bundle: .module),
                keywords: ["private", "incognito", "browser", "off the record"], category: .window,
                symbol: "eyeglasses", surfaces: [.palette, .keyboard, .menu],
                cliName: "app new-incognito-window", mainMenu: .window
            ),
            ActionDescriptor(
                id: "closeWindow",
                title: String(localized: "action.closeWindow", defaultValue: "Close Window", bundle: .module),
                defaultShortcut: Shortcut("w", modifiers: [.control, .command]), category: .window,
                symbol: "xmark.rectangle", surfaces: [.palette, .keyboard], cliName: "app close-window"
            ),
            ActionDescriptor(
                id: "minimizeWindow",
                title: String(localized: "action.minimizeWindow", defaultValue: "Minimize", bundle: .module),
                keywords: ["dock", "hide", "miniaturize"], category: .window, symbol: "minus.rectangle",
                surfaces: [.palette], cliName: "app minimize-window"
            ),
            ActionDescriptor(
                id: "toggleFullScreen",
                title: String(localized: "action.toggleFullScreen", defaultValue: "Toggle Full Screen", bundle: .module),
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
                id: "quit", title: String(localized: "action.quit", defaultValue: "Quit cmux", bundle: .module),
                keywords: ["exit", "close"], defaultShortcut: Shortcut("q", modifiers: [.command]), category: .window,
                symbol: "power", surfaces: [.keyboard, .menu],
                arguments: [
                    ActionArgument(name: "keepSessions",
                                   title: String(localized: "argument.keepSessions", defaultValue: "Keep Sessions Running", bundle: .module),
                                   kind: .bool, isRequired: false),
                    ActionArgument(name: "endSessions",
                                   title: String(localized: "argument.endSessionsKeepLayout", defaultValue: "End Sessions, Keep Layout", bundle: .module),
                                   kind: .bool, isRequired: false),
                    ActionArgument(name: "endEverything",
                                   title: String(localized: "argument.endEverything", defaultValue: "End Everything", bundle: .module),
                                   kind: .bool, isRequired: false),
                ],
                cliName: "app quit", mainMenu: .app
            ),
            ActionDescriptor(
                id: "quitKeepSessions",
                title: String(localized: "action.quitKeepSessions", defaultValue: "Quit and Keep Sessions", bundle: .module),
                keywords: ["exit", "close", "background", "terminals", "cmux-tui", "detach"], category: .window,
                symbol: "power", surfaces: [.palette, .menu], cliName: "app quit-keep-sessions", mainMenu: .app
            ),
            ActionDescriptor(
                id: "quitEndSessions",
                title: String(localized: "action.quitEndSessionsKeepLayout", defaultValue: "Quit and End Sessions, Keep Layout", bundle: .module),
                keywords: ["exit", "close", "kill", "terminals", "cmux-tui", "stop", "layout"], category: .window,
                symbol: "power", surfaces: [.palette, .menu], cliName: "app quit-end-sessions", mainMenu: .app
            ),
            ActionDescriptor(
                id: "quitEndEverything",
                title: String(localized: "action.quitEndEverything", defaultValue: "Quit and End Everything", bundle: .module),
                keywords: ["exit", "close", "kill", "terminals", "cmux-tui", "stop", "workspaces", "fresh", "reset"], category: .window,
                symbol: "power", surfaces: [.palette, .menu], cliName: "app quit-end-everything", mainMenu: .app
            ),
            ActionDescriptor(
                id: "showHideAllWindows",
                title: String(localized: "action.showHideAllWindows", defaultValue: "Show/Hide All Windows", bundle: .module),
                keywords: ["global", "hotkey", "summon"],
                defaultShortcut: Shortcut(".", modifiers: [.control, .option, .command]), category: .window,
                symbol: "macwindow.on.rectangle", surfaces: [.keyboard], cliName: "app show-hide-all-windows"
            ),
            ActionDescriptor(
                id: "globalSearch",
                title: String(localized: "action.globalSearch", defaultValue: "Search All Windows…", bundle: .module),
                keywords: ["find", "global"], defaultShortcut: Shortcut("f", modifiers: [.option, .command]),
                category: .window, symbol: "magnifyingglass", surfaces: [.palette, .keyboard, .menu],
                arguments: [CatalogArgument.textString],
                cliName: "app search-all-windows", mainMenu: .window
            ),
            ActionDescriptor(
                id: "commandPalette",
                title: String(localized: "action.commandPalette", defaultValue: "Command Palette…", bundle: .module),
                keywords: ["actions", "commands", "search"],
                defaultShortcut: Shortcut("p", modifiers: [.command, .shift]), category: .window, symbol: "command",
                surfaces: [.keyboard, .menu], cliName: "app command-palette", mainMenu: .window
            ),
            ActionDescriptor(
                id: "commandPaletteNext",
                title: String(localized: "action.commandPaletteNext", defaultValue: "Palette: Select Next Item", bundle: .module),
                defaultShortcut: Shortcut("n", modifiers: [.control]), category: .window, symbol: "chevron.down",
                surfaces: [.keyboard], requires: [.paletteOpen], cliName: "app palette-select-next-item"
            ),
            ActionDescriptor(
                id: "commandPalettePrevious",
                title: String(localized: "action.commandPalettePrevious", defaultValue: "Palette: Select Previous Item", bundle: .module),
                defaultShortcut: Shortcut("p", modifiers: [.control]), category: .window, symbol: "chevron.up",
                surfaces: [.keyboard], requires: [.paletteOpen], cliName: "app palette-select-previous-item"
            ),
            ActionDescriptor(
                id: "goToWorkspace",
                title: String(localized: "action.goToWorkspace", defaultValue: "Go to Workspace…", bundle: .module),
                keywords: ["switch", "jump", "switcher"], defaultShortcut: Shortcut("p", modifiers: [.command]),
                category: .window, symbol: "arrow.right.square", surfaces: [.keyboard, .menu],
                arguments: [CatalogArgument.workspaceWorkspace], cliName: "app go-to-workspace", mainMenu: .window
            ),
            ActionDescriptor(
                id: "palette.openTaskManager",
                title: String(localized: "action.palette.openTaskManager", defaultValue: "Task Manager", bundle: .module),
                keywords: ["processes", "cpu", "memory", "activity"], category: .window,
                symbol: "gauge.with.dots.needle.33percent", surfaces: [.palette, .menu], cliName: "app task-manager",
                mainMenu: .window
            ),
            ActionDescriptor(
                id: "palette.sleepyMode",
                title: String(localized: "action.palette.sleepyMode", defaultValue: "Sleepy Mode", bundle: .module),
                keywords: ["idle", "pause", "battery"], category: .window, symbol: "moon.zzz",
                surfaces: [.palette, .menu], cliName: "app sleepy-mode", mainMenu: .window
            ),
            ActionDescriptor(
                id: "keepMacAwake",
                title: String(localized: "action.keepMacAwake", defaultValue: "Keep Mac Awake", bundle: .module),
                keywords: ["caffeinate", "sleep"], category: .window, symbol: "cup.and.saucer", surfaces: [.menu],
                cliName: "app keep-mac-awake", mainMenu: .app
            ),
            ActionDescriptor(
                id: "showMainWindow",
                title: String(localized: "action.showMainWindow", defaultValue: "Show cmux", bundle: .module),
                keywords: ["open", "window"], category: .window, symbol: "macwindow", surfaces: [.menu],
                cliName: "app show", mainMenu: .window
            ),
            ActionDescriptor(
                id: "about", title: String(localized: "action.about", defaultValue: "About cmux", bundle: .module),
                keywords: ["version"], category: .window, symbol: "info.circle", surfaces: [.menu],
                cliName: "app about", mainMenu: .app
            ),
            ActionDescriptor(
                id: "taskManager.killProcess",
                title: String(localized: "action.taskManager.killProcess", defaultValue: "Kill Process…", bundle: .module),
                keywords: ["terminate", "signal"], category: .window, symbol: "xmark.octagon", surfaces: [.contextMenu],
                arguments: [CatalogArgument.processString], cliName: "app kill-process"
            ),
        ]
    }
}
