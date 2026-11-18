/// The off-by-default gate that applies the appearance tuning (Hue, Saturation, Glass
/// Transparency) to the window tint; off, the tuning has no effect.
public struct ExperimentalAppearanceSetting: Sendable {
    /// Creates the setting parser.
    public init() {}

    /// Parses a bool, treating an absent value as the default (off).
    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Bool {
        guard let value = root.value(at: Self.configPath) else { return Self.fallback }
        guard let enabled = value.boolValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.experimentalControls",
                                                  message: "expected true or false"))
            return Self.fallback
        }
        return enabled
    }
}
