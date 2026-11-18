public extension SettingsController {
    /// The person's settings file (``fileRoot``) with the active theme file's values over it, except
    /// keys a managed layer sets: what a reader of the file's own values sees once a theme file
    /// sets them too. The agent chat's look reads it (``AgentPaneDisplaySetting``), so a theme's
    /// `agentPane.display.font.*` and `agentPane.display.code.family` reach the chat. Observable:
    /// it changes with either file.
    var fileRootWithThemeFile: JSONValue {
        guard let themeFile else { return fileRoot }
        return themeFile.applied(to: fileRoot, managed: Set(managedKeys.keys))
    }
}
