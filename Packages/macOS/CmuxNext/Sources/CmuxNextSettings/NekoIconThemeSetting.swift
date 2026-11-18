import CmuxNextActions
import CmuxNextDesign

/// The persisted icon-family choice reserved for the optional Neko artwork.
///
/// The key is intentionally hidden from the Settings page while the artwork is
/// under review. A manually authored config can contain `neko`;
/// until a reviewed set is enabled, that value has the same
/// effective drawing as `default`.
public nonisolated enum NekoIconTheme: String, CaseIterable, Sendable {
    case `default`
    case neko
}

/// Its path, default and descriptor are generated from schemas/settings/source/appearance.json.
public nonisolated struct NekoIconThemeSetting: Sendable {
    public init() {}

    /// Parses the reserved value. `neko` is accepted for forward-compatible
    /// config files but deliberately resolves to the default artwork for now.
    public static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> NekoIconTheme {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, NekoIconTheme(rawValue: text) != nil else {
            let choices = NekoIconTheme.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        // Keep this explicit so enabling the family later is one reviewed seam.
        return fallback
    }
}
