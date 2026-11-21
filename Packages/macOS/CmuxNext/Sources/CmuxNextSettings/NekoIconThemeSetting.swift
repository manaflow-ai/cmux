import CmuxNextActions
import CmuxNextDesign

/// `appearance.iconTheme`: the optional Neko icon family (cat drawings of the action icons), off by default.
/// The App reads it at launch; native icons change after a relaunch, agent pages when they next load.
public nonisolated enum NekoIconTheme: String, CaseIterable, Sendable {
    case `default`
    case neko
}

/// Its path, default and descriptor are generated from schemas/settings/source/appearance.json.
public nonisolated struct NekoIconThemeSetting: Sendable {
    public init() {}

    /// Parses the value; anything but `default` or `neko` reports a diagnostic and draws the default.
    public static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> NekoIconTheme {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, let theme = NekoIconTheme(rawValue: text) else {
            let choices = NekoIconTheme.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        return theme
    }
}
