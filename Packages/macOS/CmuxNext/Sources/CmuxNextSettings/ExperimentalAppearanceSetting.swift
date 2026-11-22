/// The off-by-default gate for the wallpaper grid and live appearance tuner.
public struct ExperimentalAppearanceSetting: Sendable {
    /// The shared Settings and cmux.json path.
    public let configPath = ["appearance", "experimentalControls"]

    /// Creates the setting parser.
    public init() {}

    /// Parses a bool, treating an absent value as off.
    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Bool {
        guard let value = root.value(at: configPath) else { return false }
        guard let enabled = value.boolValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.experimentalControls",
                                                  message: "expected true or false"))
            return false
        }
        return enabled
    }
}
