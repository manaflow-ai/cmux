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
                SettingChoice(NewTabTemplate.threads.rawValue, SettingsText.keyed("settings.choice.newTabTemplateThreads", "Threads")),
                SettingChoice(NewTabTemplate.console.rawValue, SettingsText.keyed("settings.choice.newTabTemplateConsole", "Console")),
                SettingChoice(NewTabTemplate.classic.rawValue, SettingsText.keyed("settings.choice.newTabTemplateClassic", "Classic")),
                SettingChoice(NewTabTemplate.terminal.rawValue, SettingsText.keyed("settings.choice.newTabTemplateTerminal", "Terminal")),
            ]),
            default: .string(NewTabTemplate.fallback.rawValue),
            keywords: ["new tab", "template", "layout", "page", "minimal", "greeting", "terminal", "classic", "threads", "console", "cards", "search", "ask"]
        )
    }

    /// `newTerminal.opensWorkspace`: whether New Terminal creates a workspace
    /// in the current space instead of a tab in the focused workspace.
    static func newTerminalOpensWorkspace(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            NewTerminalWorkspaceSetting.configPath, section: .general, group: group,
            title: SettingsText.keyed("settings.newTerminal.opensWorkspace", "New Terminal Opens a Workspace"),
            help: SettingsText.keyed("settings.newTerminal.opensWorkspace.help",
                                     "Create a new workspace in the current space instead of a tab. Hold Option to reverse this for one click."),
            kind: .toggle,
            default: .bool(NewTerminalWorkspaceSetting.fallback),
            keywords: ["new terminal", "workspace", "space", "tab", "option"]
        )
    }

    /// `tabs.nativeNewTabPage`: the native New Tab page, an alternative to the web one (off by default).
    static func nativeNewTabPage(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            NativeNewTabPageSetting.configPath, section: .general, group: group,
            title: SettingsText.keyed("settings.tabs.nativeNewTabPage", "Native New Tab Page"),
            help: SettingsText.keyed("settings.tabs.nativeNewTabPage.help",
                                     "Cmd-T and the + button open the native New Tab page instead of the web one. It opens faster and lists every command palette action as you type. Recent chats and widgets are only on the web page for now."),
            kind: .toggle,
            default: .bool(NativeNewTabPageSetting.fallback),
            keywords: ["new tab", "native", "swift", "page", "cmd-t", "fast", "web", "alternative", "command palette", "actions"]
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
