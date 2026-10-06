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

    /// `app.warnBeforeClosingTab` and `app.warnBeforeClosingAgentSession`,
    /// side by side as in classic.
    static func closeWarnings(group: SettingText) -> [SettingDescriptor] {
        [
            SettingDescriptor(
                CloseWarningSetting.tabPath, section: .general, group: group,
                title: SettingsText.keyed("settings.app.warnBeforeClosingTab", "Warn Before Closing a Running Program"),
                help: SettingsText.keyed("settings.app.warnBeforeClosingTab.help",
                                        "Ask before closing a tab or workspace whose terminal is running a program. Idle tabs always close at once."),
                kind: .toggle,
                default: .bool(CloseWarningSetting.fallback),
                keywords: ["close", "confirm", "warn", "tab", "workspace", "running", "process", "cmd-w"]
            ),
            SettingDescriptor(
                CloseWarningSetting.agentSessionPath, section: .general, group: group,
                title: SettingsText.keyed("settings.app.warnBeforeClosingAgentSession", "Warn Before Closing a Working Agent"),
                help: SettingsText.keyed("settings.app.warnBeforeClosingAgentSession.help",
                                        "Ask before closing a terminal tab whose agent is still working."),
                kind: .toggle,
                default: .bool(CloseWarningSetting.fallback),
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
