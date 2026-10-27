import CmuxNextDesign


/// The Tabs rows of the General section (its own type: the schema type's line budget is per type).
nonisolated enum TabSettingsSchema {
    /// `tabs.newTabPosition`: where Cmd-T and the strip's + put the new tab (cx-d0d.58).
    static func newTabPosition(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            NewTabPosition.configPath, section: .general, group: group,
            title: SettingsText.keyed("settings.tabs.newTabPosition", "New Tab Position"),
            help: SettingsText.keyed("settings.tabs.newTabPosition.help",
                                    "Where Cmd-T and the + button put the new tab. New Tab to the Right in a tab's menu always puts it after that tab."),
            kind: .choice([
                SettingChoice(NewTabPosition.afterCurrent.rawValue, SettingsText.keyed("settings.choice.newTabPositionAfterCurrent", "After the Current Tab")),
                SettingChoice(NewTabPosition.end.rawValue, SettingsText.keyed("settings.choice.newTabPositionEnd", "At the End")),
                SettingChoice(NewTabPosition.start.rawValue, SettingsText.keyed("settings.choice.newTabPositionStart", "At the Start")),
            ]),
            default: .string(NewTabPosition.fallback.rawValue),
            keywords: ["new tab", "cmd-t", "position", "order", "right", "end", "after", "start", "first", "beginning", "insert"]
        )
    }

    /// `tabs.newTabTemplate`: which New Tab page template shows (the page's dots also set it).
    static func newTabTemplate(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            NewTabTemplate.configPath, section: .general, group: group,
            title: SettingsText.keyed("settings.tabs.newTabTemplate", "New Tab Template"),
            help: SettingsText.keyed("settings.tabs.newTabTemplate.help",
                                     "The layout of the New Tab page. Terminal skips the page and opens a terminal. The dots at the bottom of the page also change it."),
            kind: .choice([
                SettingChoice(NewTabTemplate.minimal.rawValue, SettingsText.keyed("settings.choice.newTabTemplateMinimal", "Minimal")),
                SettingChoice(NewTabTemplate.cards.rawValue, SettingsText.keyed("settings.choice.newTabTemplateCards", "Cards")),
                SettingChoice(NewTabTemplate.default.rawValue, SettingsText.keyed("settings.choice.newTabTemplateDefault", "Default")),
                SettingChoice(NewTabTemplate.composer.rawValue, SettingsText.keyed("settings.choice.newTabTemplateComposer", "Composer")),
                SettingChoice(NewTabTemplate.threads.rawValue, SettingsText.keyed("settings.choice.newTabTemplateThreads", "Threads")),
                SettingChoice(NewTabTemplate.console.rawValue, SettingsText.keyed("settings.choice.newTabTemplateConsole", "Console")),
                SettingChoice(NewTabTemplate.classic.rawValue, SettingsText.keyed("settings.choice.newTabTemplateClassic", "Classic")),
                SettingChoice(NewTabTemplate.terminal.rawValue, SettingsText.keyed("settings.choice.newTabTemplateTerminal", "Terminal")),
            ]),
            default: .string(NewTabTemplate.fallback.rawValue),
            keywords: ["new tab", "template", "layout", "page", "minimal", "greeting", "terminal", "classic", "composer", "threads", "console", "cards", "search", "ask"]
        )
    }

    /// `newTerminal.opensWorkspace`: whether New Terminal creates a workspace
    /// in the current space instead of a tab in the focused workspace, and a
    /// person's Cmd-N a terminal workspace instead of the New Tab page (#26051).
    static func newTerminalOpensWorkspace(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            NewTerminalWorkspaceSetting.configPath, section: .general, group: group,
            title: SettingsText.keyed("settings.newTerminal.opensWorkspace", "New Terminal Opens a Workspace (cmux classic)"),
            help: SettingsText.keyed("settings.newTerminal.opensWorkspace.help",
                                     "New Terminal and Cmd-N create a workspace with a terminal in the current folder, as in cmux classic. Hold Option when clicking New Terminal to reverse this once."),
            kind: .toggle,
            default: .bool(NewTerminalWorkspaceSetting.fallback),
            keywords: ["new terminal", "workspace", "space", "tab", "option", "classic", "cmd-n"]
        )
    }

    /// `tabs.terminalFirst`, shown as cmux Classic Mode: every new tab, split, workspace and window a
    /// person opens is a terminal, as in cmux classic (#23021). The help says how to reach the GUI.
    static func terminalFirst(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            TerminalFirstSetting.configPath, section: .general, group: group,
            title: SettingsText.keyed("settings.tabs.terminalFirst", "cmux Classic Mode"),
            help: SettingsText.keyed("settings.tabs.terminalFirst.help",
                                     "New tabs (Cmd-T, the tab bar's +), splits (Cmd-D, Cmd-Shift-D), new workspaces (Cmd-N, the sidebar's +) and new windows open a terminal, as in cmux classic, instead of the New Tab page. To open the New Tab page while this is on, right-click or press and hold the tab bar's +, or run New Tab Page from the command palette (Cmd-Shift-P). Cmd-I still opens an agent chat and Cmd-Shift-L a browser tab."),
            kind: .toggle,
            default: .bool(TerminalFirstSetting.fallback),
            keywords: ["terminal", "classic", "classic mode", "cmux classic", "new tab", "split", "workspace", "window", "cmd-t", "cmd-d", "cmd-n", "new tab page", "gui", "default"]
        )
    }

    /// `tabs.cmdWClosesPinnedTabs`: whether the user's Cmd-W closes a pinned tab.
    static func cmdWClosesPinnedTabs(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            CmdWClosesPinnedTabsSetting.configPath, section: .general, group: group,
            title: SettingsText.keyed("settings.tabs.cmdWClosesPinnedTabs", "Cmd-W Closes Pinned Tabs"),
            help: SettingsText.keyed("settings.tabs.cmdWClosesPinnedTabs.help",
                                     "When off, Cmd-W on a pinned tab selects the next tab and keeps the pinned tab. Close a pinned tab from its menu."),
            kind: .toggle,
            default: .bool(CmdWClosesPinnedTabsSetting.fallback),
            keywords: ["pin", "pinned", "close", "cmd-w", "tab", "keep"]
        )
    }

    /// `tabs.swapCmdTAndCmdN`: Cmd-T opens a workspace and Cmd-N a tab.
    static func swapCmdTAndCmdN(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            SwapCmdTAndCmdNSetting.configPath, section: .general, group: group,
            title: SettingsText.keyed("settings.tabs.swapCmdTAndCmdN", "Swap Cmd-T and Cmd-N"),
            help: SettingsText.keyed("settings.tabs.swapCmdTAndCmdN.help",
                                     "When on, Cmd-T opens a workspace in the current group and Cmd-N opens a tab. When off, Cmd-T opens a tab, or a workspace when an agent chat or a pane without tabs is focused."),
            kind: .toggle,
            default: .bool(SwapCmdTAndCmdNSetting.fallback),
            keywords: ["cmd-t", "cmd-n", "swap", "new tab", "new workspace", "shortcut", "keyboard"]
        )
    }

    /// `app.warnBeforeClosingTab` and `app.warnBeforeClosingAgentSession`,
    /// side by side as in classic.
    static func closeWarnings(group: SettingText) -> [SettingDescriptor] {
        [
            SettingDescriptor(
                CmuxConfigSnapshot.warnBeforeClosingTabPath, section: .general, group: group,
                title: SettingsText.keyed("settings.app.warnBeforeClosingTab", "Warn Before Closing a Running Program"),
                kind: .toggle,
                default: .bool(CmuxConfigSnapshot.closeWarningFallback),
                keywords: ["close", "confirm", "warn", "tab", "workspace", "running", "process", "cmd-w"]
            ),
            SettingDescriptor(
                CmuxConfigSnapshot.warnBeforeClosingAgentSessionPath, section: .general, group: group,
                title: SettingsText.keyed("settings.app.warnBeforeClosingAgentSession", "Warn Before Closing a Working Agent"),
                kind: .toggle,
                default: .bool(CmuxConfigSnapshot.closeWarningFallback),
                keywords: ["close", "confirm", "warn", "agent", "claude", "codex", "session", "working", "cmd-w"]
            ),
        ]
    }

    /// `tabs.plusButton` (R120): whether each tab bar's + shows only on hover.
    static func plusButton(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            PlusButtonSetting.configPath, section: .general, group: group,
            title: SettingsText.keyed("settings.tabs.plusButton", "New Tab Button"),
            help: SettingsText.keyed("settings.tabs.plusButton.help", "On Hover shows each tab bar's + only while the pointer is over that tab bar."),
            kind: .choice([
                SettingChoice(PlusButtonMode.hover.rawValue, SettingsText.keyed("settings.choice.onHover", "On Hover")),
                SettingChoice(PlusButtonMode.always.rawValue, SettingsText.keyed("settings.choice.always", "Always")),
            ]),
            default: .string(PlusButtonSetting.fallback.rawValue),
            keywords: ["plus", "+", "new tab", "button", "hover", "tab bar"]
        )
    }
}
