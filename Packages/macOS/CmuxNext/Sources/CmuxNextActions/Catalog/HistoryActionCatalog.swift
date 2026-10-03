// History (plans/cmux-next/history.md): the location trail (Go Back / Go
// Forward), the history page and palette pages, clearing, and layout undo.
// Page history stays `browserBack` / `browserForward` (Cmd-[ / Cmd-]).
// Titles live in HistoryActions.xcstrings.

nonisolated enum HistoryActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            // The ids are the cmux.json shortcut keys of the old Focus
            // Back/Forward rows, so user bindings keep working.
            ActionDescriptor(
                id: "focusHistoryBack", title: t("action.history.back", "Go Back"),
                keywords: ["history", "previous", "location", "jump", "back", "where"],
                defaultShortcut: Shortcut(Shortcut.leftArrowKey, modifiers: [.control, .command]),
                category: .window, symbol: "chevron.backward", surfaces: [.palette, .keyboard, .menu],
                cliName: "history back", mainMenu: .window
            ),
            ActionDescriptor(
                id: "focusHistoryForward", title: t("action.history.forward", "Go Forward"),
                keywords: ["history", "next", "location", "jump", "forward"],
                defaultShortcut: Shortcut(Shortcut.rightArrowKey, modifiers: [.control, .command]),
                category: .window, symbol: "chevron.forward", surfaces: [.palette, .keyboard, .menu],
                cliName: "history forward", mainMenu: .window
            ),
            ActionDescriptor(
                id: "focusHistoryLast", title: t("action.history.last", "Go to Last Location"),
                keywords: ["history", "toggle", "recent", "location", "alternate"], category: .window,
                symbol: "arrow.uturn.backward", surfaces: [.palette, .keyboard, .menu], cliName: "history last",
                mainMenu: .window
            ),
            ActionDescriptor(
                id: "recentlyFocused", title: t("action.history.locations", "Location History…"),
                keywords: ["history", "recent", "locations", "jumplist", "trail"], category: .window, symbol: "clock",
                surfaces: [.palette, .keyboard, .menu], cliName: "history locations", mainMenu: .window
            ),
            ActionDescriptor(
                id: "recentlyClosed", title: t("action.history.closed", "Recently Closed…"),
                keywords: ["history", "reopen", "undo", "closed", "restore"], category: .window,
                symbol: "clock.arrow.circlepath", surfaces: [.palette, .keyboard, .menu], cliName: "history closed",
                mainMenu: .window
            ),
            ActionDescriptor(
                id: "history.commands", title: t("action.history.commands", "Command History…"),
                keywords: ["history", "commands", "shell", "terminal", "run again"], category: .window, symbol: "terminal",
                surfaces: [.palette, .keyboard, .menu], cliName: "history commands", mainMenu: .window
            ),
            ActionDescriptor(
                id: "history.show", title: t("action.history.show", "Show History"),
                keywords: ["history", "pages", "visited", "cmux://history", "timeline"], category: .window,
                symbol: "clock.fill", surfaces: [.palette, .keyboard, .menu], cliName: "history show", mainMenu: .window
            ),
            // Cmd-Y shows history in a page; elsewhere Cmd-Y stays New Cloud Machine.
            ActionDescriptor(
                id: "browserShowHistory", title: t("action.history.showFromPage", "Show History"),
                keywords: ["history", "browser"], defaultShortcut: Shortcut("y", modifiers: [.command]),
                category: .browser, symbol: "clock.fill", surfaces: [.keyboard], requires: [.browserFocused],
                cliName: "browser show-history"
            ),
            ActionDescriptor(
                id: "history.search", title: t("action.history.search", "Search History…"),
                keywords: ["history", "find", "pages", "commands", "agents", "locations"], category: .window,
                symbol: "magnifyingglass", surfaces: [.palette, .keyboard, .menu], cliName: "history search-in-palette",
                mainMenu: .window
            ),
            ActionDescriptor(
                id: "history.resumeAgentSession", title: t("action.history.resumeAgent", "Resume Agent Session…"),
                keywords: ["history", "agent", "claude", "codex", "resume", "session", "continue"], category: .agents,
                symbol: "arrow.clockwise.circle", surfaces: [.palette, .keyboard, .menu],
                arguments: [ActionArgument(name: "session", title: t("argument.history.session", "Session ID"), kind: .string, isRequired: false)],
                cliName: "history resume", mainMenu: .window
            ),
            ActionDescriptor(
                id: "history.reopen", title: t("action.history.reopen", "Reopen Last Closed Item"),
                keywords: ["history", "reopen", "undo", "closed", "tab", "screen"], category: .window,
                symbol: "arrow.uturn.backward.circle", surfaces: [.palette, .keyboard], cliName: "history reopen"
            ),
            ActionDescriptor(
                id: "history.clear", title: t("action.history.clear", "Clear History…"),
                keywords: ["history", "privacy", "delete", "forget", "clear"], category: .window, symbol: "clock.badge.xmark",
                surfaces: [.palette, .keyboard, .menu],
                arguments: [historyRange, historyKind], cliName: "history clear", mainMenu: .window
            ),
            ActionDescriptor(
                id: "layout.undo", title: t("action.layout.undo", "Undo Layout Change"),
                keywords: ["undo", "layout", "split", "resize", "history", "revert"], category: .pane,
                symbol: "arrow.uturn.backward.square", surfaces: [.palette, .keyboard, .menu], targets: [.pane],
                cliName: "layout undo", mainMenu: .view
            ),
        ]
    }

    private static var historyRange: ActionArgument {
        ActionArgument(name: "range", title: t("argument.history.range", "Time Range"), kind: .enumeration([
            ActionEnumCase(value: "hour", title: t("argument.history.range.hour", "Last Hour")),
            ActionEnumCase(value: "today", title: t("argument.history.range.today", "Today")),
            ActionEnumCase(value: "week", title: t("argument.history.range.week", "Last 7 Days")),
            ActionEnumCase(value: "month", title: t("argument.history.range.month", "Last 4 Weeks")),
            ActionEnumCase(value: "all", title: t("argument.history.range.all", "All Time")),
        ]))
    }

    private static var historyKind: ActionArgument {
        ActionArgument(name: "kind", title: t("argument.history.kind", "Kind"), kind: .enumeration([
            ActionEnumCase(value: "all", title: t("argument.history.kind.all", "Everything")),
            ActionEnumCase(value: "page", title: t("argument.history.kind.page", "Pages")),
            ActionEnumCase(value: "location", title: t("argument.history.kind.location", "Locations")),
            ActionEnumCase(value: "closed", title: t("argument.history.kind.closed", "Closed Items")),
            ActionEnumCase(value: "agent", title: t("argument.history.kind.agent", "Agent Sessions")),
            ActionEnumCase(value: "command", title: t("argument.history.kind.command", "Commands")),
        ]), isRequired: false)
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "HistoryActions", bundle: .module)
    }
}
