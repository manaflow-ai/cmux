public import CmuxNextActions
public import CmuxNextDesign

/// The palette's one-choice actions of `tabs.barPosition` and `tabs.newTabPosition` (user
/// 2026-10-27): Tab Bar Position: Top, Bottom, Left (Vertical), Right (Vertical)
/// (`tabs.barPosition.<value>`) and New Tabs Open: After the Current Tab, Before the Current Tab, At
/// the Start, At the End (`tabs.newTabPosition.<value>`). Each saves its value (the default removes
/// the key; refused while the key is managed); the CLI and MCP reach them by their `settings` verbs.
public nonisolated struct TabPlacementSetting: Sendable {
    public init() {}

    /// The cmux.json value for a tab bar position: top, the default, removes the key.
    public static func fileValue(_ position: TabBarPosition) -> JSONValue? {
        position == .top ? nil : .string(position.rawValue)
    }

    /// The cmux.json value for a new tab position: after the current tab, the default, removes the key.
    public static func fileValue(_ position: NewTabPosition) -> JSONValue? {
        position == NewTabPosition.fallback ? nil : .string(position.rawValue)
    }
}

extension TabPlacementSetting {
    /// Binds every `tabs.barPosition.<value>` and `tabs.newTabPosition.<value>` action. A tab bar
    /// action moves every pane's bar at once (`DesignSettings.tabBarPosition`); a new tab position
    /// takes effect when the file watcher reloads the settings, which Cmd-T reads. No preview: a
    /// highlighted palette row must not relayout every pane.
    @MainActor public static func bindActions(into registry: ActionRegistry, design: DesignSettings, save: @escaping SettingChoiceActions.Save) {
        SettingChoiceActions.bind(TabBarPosition.allCases, into: registry, id: { "tabs.barPosition.\($0.rawValue)" },
                                  path: ChromePlacementSetting.tabBarPositionPath, fileValue: { fileValue($0) }, save: save) {
            design.tabBarPosition = $0
        }
        SettingChoiceActions.bind(NewTabPosition.allCases, into: registry, id: { "tabs.newTabPosition.\($0.rawValue)" },
                                  path: NewTabPosition.configPath, fileValue: { fileValue($0) }, save: save) { _ in }
    }
}
