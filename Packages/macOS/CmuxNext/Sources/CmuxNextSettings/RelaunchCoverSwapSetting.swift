// The path, default and the RelaunchCoverSwap enum are generated from schemas/settings/source/developer-tools.json
// (Schema/SettingsSchema+DeveloperTools*.generated.swift).

/// `launch.relaunchCoverSwap` in cmux-next.json: how an app relaunch (an update, or
/// `cmux app quit --keep-sessions`) swaps each window's saved picture for its live content. `off` (the default)
/// shows no picture; `instant` removes a window's picture in one frame once all its panes are ready; `crossfade`
/// fades it out over 120 ms then; `progressive` fades each pane's region over 80 ms as that pane is
/// ready. A comparison setting: a row in Settings > Development and the Command Palette in DEV and NIGHTLY;
/// the CLI and MCP set it in every build.
public nonisolated struct RelaunchCoverSwapSetting: Sendable {
    public init() {}
    public static let key = configPath.joined(separator: ".")

    /// A missing key is the default with no diagnostic; a bad value is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (RelaunchCoverSwap, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let swap = RelaunchCoverSwap(rawValue: text) else {
            let choices = RelaunchCoverSwap.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: key, message: "expected one of \(choices)"))
        }
        return (swap, nil)
    }
}
