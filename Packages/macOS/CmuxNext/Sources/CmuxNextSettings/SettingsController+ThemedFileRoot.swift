public extension SettingsController {
    /// The person's settings file (``fileRoot``) with the active theme file's values over it, except
    /// keys a managed layer sets: what a reader of the file's own values sees once a theme file
    /// sets them too, so a theme's `agentPane.display.font.*` and `agentPane.display.code.family`
    /// reach the chat. Observable: it changes with either file.
    var fileRootWithThemeFile: JSONValue {
        guard let themeFile else { return fileRoot }
        return themeFile.applied(to: fileRoot, managed: Set(managedKeys.keys))
    }

    /// What the agent chat's look is read from (``AgentPaneDisplaySetting/read(fileRoot:managedHarnessPlacement:fontFaces:)``):
    /// ``fileRootWithThemeFile`` and the managed `agentPane.display.harnessPlacement`, if a managed
    /// layer sets it. Observable.
    var chatDisplayInputs: (root: JSONValue, managedHarnessPlacement: JSONValue?) {
        let path = AgentPaneDisplaySettingsSchema.harnessPlacementPath
        let managed = managedKeys[path.joined(separator: ".")].flatMap { _ in snapshot.root.value(at: path) }
        return (fileRootWithThemeFile, managed)
    }
}
