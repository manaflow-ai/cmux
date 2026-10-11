import CmuxNextDesign


/// The Tabs rows of the General section (its own type: the schema type's line budget is per type).
nonisolated enum TabSettingsSchema {
    /// `tabs.newTabKind`: what Cmd-T and the strip's + button open.
    static func newTabKind(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            NewTabDefaultKind.configPath, section: .general, group: group,
            title: SettingsText.keyed("settings.tabs.newTabKind", "New Tab Opens"),
            help: SettingsText.keyed("settings.tabs.newTabKind.help",
                                    "What Cmd-T and the + button open. Auto picks the kind you last opened in that folder."),
            kind: .choice([
                SettingChoice(NewTabDefaultKind.sameKind.rawValue, SettingsText.keyed("settings.choice.newTabSameKind", "Same Kind as Current Tab")),
                SettingChoice(NewTabDefaultKind.terminal.rawValue, SettingsText.keyed("settings.choice.newTabTerminal", "Terminal")),
                SettingChoice(NewTabDefaultKind.browser.rawValue, SettingsText.keyed("settings.choice.newTabBrowser", "Browser")),
                SettingChoice(NewTabDefaultKind.agent.rawValue, SettingsText.keyed("settings.choice.newTabAgent", "Agent")),
                SettingChoice(NewTabDefaultKind.page.rawValue, SettingsText.keyed("settings.choice.newTabPage", "New Tab Page")),
                SettingChoice(NewTabDefaultKind.auto.rawValue, SettingsText.keyed("settings.choice.newTabAuto", "Auto")),
            ]),
            default: .string(NewTabDefaultKind.fallback.rawValue),
            keywords: ["new tab", "cmd-t", "terminal", "browser", "agent", "kind", "default"]
        )
    }

    /// `tabs.newTabPosition`: where Cmd-T and the strip's + put the new tab (cx-d0d.58).
    static func newTabPosition(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            NewTabPosition.configPath, section: .general, group: group,
            title: SettingsText.keyed("settings.tabs.newTabPosition", "New Tab Position"),
            help: SettingsText.keyed("settings.tabs.newTabPosition.help",
                                    "Where Cmd-T and the + button put the new tab. New Tab to the Right in a tab's menu always puts it after that tab."),
            kind: .choice([
                SettingChoice(NewTabPosition.end.rawValue, SettingsText.keyed("settings.choice.newTabPositionEnd", "At the End")),
                SettingChoice(NewTabPosition.afterCurrent.rawValue, SettingsText.keyed("settings.choice.newTabPositionAfterCurrent", "After the Current Tab")),
            ]),
            default: .string(NewTabPosition.fallback.rawValue),
            keywords: ["new tab", "cmd-t", "position", "order", "right", "end", "after", "insert"]
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
                SettingChoice(NewTabTemplate.default.rawValue, SettingsText.keyed("settings.choice.newTabTemplateDefault", "Default")),
                SettingChoice(NewTabTemplate.composer.rawValue, SettingsText.keyed("settings.choice.newTabTemplateComposer", "Composer")),
                SettingChoice(NewTabTemplate.threads.rawValue, SettingsText.keyed("settings.choice.newTabTemplateThreads", "Threads")),
                SettingChoice(NewTabTemplate.console.rawValue, SettingsText.keyed("settings.choice.newTabTemplateConsole", "Console")),
                SettingChoice(NewTabTemplate.classic.rawValue, SettingsText.keyed("settings.choice.newTabTemplateClassic", "Classic")),
                SettingChoice(NewTabTemplate.terminal.rawValue, SettingsText.keyed("settings.choice.newTabTemplateTerminal", "Terminal")),
            ]),
            default: .string(NewTabTemplate.fallback.rawValue),
            keywords: ["new tab", "template", "layout", "page", "terminal", "classic", "composer", "threads", "console"]
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

    /// `tabs.tabBar.<kind>`: whether a pane of that kind shows its tab bar.
    static func paneTabBars(group: SettingText) -> [SettingDescriptor] {
        func title(_ kind: PaneTabBarKind) -> SettingText {
            switch kind {
            case .terminal: SettingsText.keyed("settings.tabs.tabBar.terminal", "Tab Bar in Terminal Panes")
            case .browser: SettingsText.keyed("settings.tabs.tabBar.browser", "Tab Bar in Browser Panes")
            case .agent: SettingsText.keyed("settings.tabs.tabBar.agent", "Tab Bar in Agent Chats")
            }
        }
        return PaneTabBarKind.allCases.map { kind in
            SettingDescriptor(
                kind.settingsPath, section: .general, group: group,
                title: title(kind),
                help: SettingsText.keyed("settings.tabs.tabBar.help",
                                         "Automatic shows the tab bar in terminal and browser panes, and hides it for an agent chat alone in its column. Show or hide one pane's tab bar from the command palette."),
                kind: .choice([
                    SettingChoice(PaneTabBarMode.auto.rawValue, SettingsText.keyed("settings.choice.tabBarAuto", "Automatic")),
                    SettingChoice(PaneTabBarMode.always.rawValue, SettingsText.keyed("settings.choice.always", "Always")),
                    SettingChoice(PaneTabBarMode.never.rawValue, SettingsText.keyed("settings.choice.never", "Never")),
                ]),
                default: .string(PaneTabBarMode.auto.rawValue),
                keywords: ["tab bar", "tabs", "strip", "horizontal", "show", "hide", kind.rawValue, "pane"]
            )
        }
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
