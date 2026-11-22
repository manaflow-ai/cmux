public import CmuxNextDesign

/// Where new panes open (`CmuxConfigSnapshot+PanePlacement`), in the General
/// section's Columns group.
nonisolated enum PanePlacementSettingsSchema {
    /// Agents may change both: layout choices, like `layout.dockColumnMode`.
    static var agentSettableKeys: Set<String> {
        [CmuxConfigSnapshot.newPanePlacementPath, CmuxConfigSnapshot.tileBrowsersPath]
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
        ]
    }
}
