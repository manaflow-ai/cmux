public import CmuxNextDesign

/// Where new panes open (`CmuxConfigSnapshot+PanePlacement`), in the General
/// section's Columns group.
nonisolated enum PanePlacementSettingsSchema {
    /// Agents may change them all: layout choices, like `layout.dockColumnMode`.
    static var agentSettableKeys: Set<String> {
        [CmuxConfigSnapshot.newPanePlacementPath, CmuxConfigSnapshot.tileBrowsersPath, LinkPlacement.configPath,
         MainPaneSetting.configPath]
            .reduce(into: []) { $0.insert($1.joined(separator: ".")) }
    }

    static var descriptors: [SettingDescriptor] {
        let columns = SettingsText.keyed("settings.group.columns", "Columns")
        return [
            SettingDescriptor(
                CmuxConfigSnapshot.newPanePlacementPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.newPanePlacement", "New Terminals and Browsers"),
                help: SettingsText.keyed("settings.layout.newPanePlacement.help",
                                        "Open a Tab adds a tab to the focused pane. Split Automatically splits the largest pane, like New Pane (Auto Layout)."),
                kind: .choice([
                    SettingChoice(NewPanePlacement.tab.rawValue, SettingsText.keyed("settings.choice.newPaneTab", "Open a Tab")),
                    SettingChoice(NewPanePlacement.split.rawValue, SettingsText.keyed("settings.choice.newPaneSplit", "Split Automatically")),
                ]),
                default: .string(CmuxConfigSnapshot.newPanePlacementFallback.rawValue),
                keywords: ["tab", "split", "pane", "auto layout", "smart arrange", "zellij", "tile"]
            ),
            SettingDescriptor(
                CmuxConfigSnapshot.tileBrowsersPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.tileBrowsers", "Split for Browsers Too"),
                help: SettingsText.keyed("settings.layout.tileBrowsers.help",
                                        "With Split Automatically, new browsers also get their own pane instead of a tab."),
                kind: .toggle, default: .bool(CmuxConfigSnapshot.tileBrowsersFallback),
                keywords: ["browser", "tile", "split", "pane", "tab"]
            ),
            SettingDescriptor(
                LinkPlacement.configPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.linkPlacement", "Open Links and Files"),
                help: SettingsText.keyed("settings.layout.linkPlacement.help",
                                        "Where a link or file you open from a terminal, an agent chat, Home or a page appears. Split Right uses the pane on the right, or makes one."),
                kind: .choice([
                    SettingChoice(LinkPlacement.splitRight.rawValue, SettingsText.keyed("settings.choice.linkPlacementSplitRight", "Split Right")),
                    SettingChoice(LinkPlacement.newColumn.rawValue, SettingsText.keyed("settings.choice.linkPlacementNewColumn", "New Column on the Right")),
                    SettingChoice(LinkPlacement.samePane.rawValue, SettingsText.keyed("settings.choice.linkPlacementSamePane", "Tab in the Same Pane")),
                ]),
                default: .string(LinkPlacement.fallback.rawValue),
                keywords: ["link", "url", "path", "file", "open", "split", "right", "column", "pane", "tab"]
            ),
            SettingDescriptor(
                MainPaneSetting.configPath, section: .general, group: columns,
                title: SettingsText.keyed("settings.layout.mainPane", "Main Pane"),
                help: SettingsText.keyed("settings.layout.mainPane.help",
                                        "Agent Chats keeps an agent chat as the main pane: links, files, subagents and side chats it opens appear as tabs in a column on its right, and closing that column gives the chat its full width back."),
                kind: .choice([
                    SettingChoice(MainPaneSetting.agentChats.rawValue, SettingsText.keyed("settings.choice.mainPaneAgentChats", "Agent Chats")),
                    SettingChoice(MainPaneSetting.off.rawValue, SettingsText.keyed("settings.choice.mainPaneOff", "Off")),
                ]),
                default: .string(MainPaneSetting.fallback.rawValue),
                keywords: ["main", "pane", "chat", "agent", "right", "column", "side", "link", "subagent", "tab"]
            ),
        ]
    }
}
