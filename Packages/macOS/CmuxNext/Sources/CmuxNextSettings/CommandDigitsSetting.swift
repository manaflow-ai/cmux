/// `tabs.commandDigits` in cmux.json: what Cmd-1…9 select. `workspaces` (the
/// default) keeps the sidebar on Cmd-1…9 and the focused pane's tabs on
/// Ctrl-1…9. `tabs` trades the two: Cmd-1…9 select tabs (Cmd-9 the last) and
/// Ctrl-1…9 workspaces. A binding the user set for either action wins, and then
/// neither moves (`SettingsApplier`), as with `tabs.swapCmdTAndCmdN`.
public nonisolated enum CommandDigitsSetting: String, CaseIterable, Sendable {
    case workspaces
    case tabs

    public static let configPath = ["tabs", "commandDigits"]
    public static let fallback = CommandDigitsSetting.workspaces

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (CommandDigitsSetting, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let parsed = CommandDigitsSetting(rawValue: text) else {
            let choices = allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "tabs.commandDigits", message: "expected one of " + choices))
        }
        return (parsed, nil)
    }

    static func descriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            configPath, section: .appearance, group: group,
            title: SettingsText.keyed("settings.tabs.commandDigits", "Command-1 to 9 Select"),
            help: SettingsText.keyed("settings.tabs.commandDigits.help",
                                     "Workspaces: Command-1 to 9 go to sidebar items and Control-1 to 9 to tabs. Tabs: Command-1 to 9 go to the focused pane's tabs and Control-1 to 9 to workspaces."),
            summary: SettingsText.keyed("settings.tabs.commandDigits.summary", "Workspaces or tabs on Command-1 to 9"),
            kind: .choice([
                SettingChoice(CommandDigitsSetting.workspaces.rawValue, SettingsText.keyed("settings.tabs.commandDigits.workspaces", "Workspaces")),
                SettingChoice(CommandDigitsSetting.tabs.rawValue, SettingsText.keyed("settings.tabs.commandDigits.tabs", "Tabs")),
            ]),
            default: .string(fallback.rawValue),
            keywords: ["command", "number", "digit", "shortcut", "tab", "workspace", "cmd-1", "switch"]
        )
    }
}
