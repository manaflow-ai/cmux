public import CmuxNextDesign

/// `appearance.paneBackgrounds`: one background behind the whole window (`shared`, the default)
/// or a copy in each pane (`perPane`); plans/cmux-next/pane-backgrounds-DESIGN.md. A missing key
/// is the default; a bad value is the default plus a diagnostic.
public nonisolated struct PaneBackgroundsSetting: Sendable {
    public init() {}

    /// The shared Settings, CLI and cmux.json path.
    public static let configPath = ["appearance", "paneBackgrounds"]

    /// Parses the key.
    ///
    /// - Parameter root: The whole cmux.json value.
    /// - Returns: The mode, and a diagnostic for a value that is not one of the modes.
    public static func parse(_ root: JSONValue) -> (PaneBackgroundMode, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (.shared, nil) }
        guard let text = value.stringValue, let mode = PaneBackgroundMode(rawValue: text) else {
            let choices = PaneBackgroundMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (.shared, SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."), message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }

    static func descriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(configPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.appearance.paneBackgrounds", "Pane Backgrounds"),
                          help: SettingsText.keyed("settings.appearance.paneBackgrounds.help",
                                                   "One background behind the whole window, or a copy in each pane. A pane's own background (right-click a pane) shows either way."),
                          summary: SettingsText.keyed("settings.appearance.paneBackgrounds.summary", "One background or one per pane"),
                          kind: .choice([
                              SettingChoice(PaneBackgroundMode.shared.rawValue,
                                            SettingsText.keyed("settings.choice.paneBackgrounds.shared", "One for the Window")),
                              SettingChoice(PaneBackgroundMode.perPane.rawValue,
                                            SettingsText.keyed("settings.choice.paneBackgrounds.perPane", "One per Pane")),
                          ]),
                          default: .string(PaneBackgroundMode.shared.rawValue),
                          keywords: ["background", "wallpaper", "pane", "split", "per pane", "each pane", "backdrop", "art"])
    }
}
