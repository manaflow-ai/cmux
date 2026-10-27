public import CmuxNextDesignTokens

/// `appearance.themeEdits` in cmux.json (cx-wqn5): per-token color edits to a theme, one entry per
/// edited token, keyed `"<theme>/<token>"`: `{"Rose Pine/background": "#1f1d2e", "Rose Pine/4":
/// "#9ccfd8"}`. Tokens are `ThemeEdits.tokens`. The edits derive "Rose Pine (custom)" and never change
/// the theme itself; removing an entry resets that token.
public nonisolated struct ThemeEditsSetting: Sendable {
    public let configPath = ["appearance", "themeEdits"]

    public init() {}

    /// The key of one edit.
    public static func key(theme: String, token: String) -> String { "\(theme)/\(token)" }

    /// A bad entry is dropped with a diagnostic at its key; the others still apply.
    func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> ThemeEdits {
        guard let value = root.value(at: configPath) else { return .none }
        let path = configPath.joined(separator: ".")
        guard case .object(let entries) = value else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected an object"))
            return .none
        }
        var colors: [String: [String: String]] = [:]
        for (key, entry) in entries {
            // One theme name exactly as the pickers write it: no pair, no prefix, no padding.
            guard let slash = key.lastIndex(of: "/"), case let name = String(key[..<slash]),
                  let theme = ThemeSpec(name), theme.light == name, theme.dark == name else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "\(path).\(key)",
                                                      message: "expected \"<theme>/<token>\", such as \"Rose Pine/background\""))
                continue
            }
            let token = String(key[key.index(after: slash)...])
            guard ThemeEdits.tokens.contains(token) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "\(path).\(key)",
                                                      message: "unknown token; expected background, foreground, cursor, selection, 0 to 15 or accent"))
                continue
            }
            guard let color = entry.stringValue, ThemeEdits.isColor(color) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "\(path).\(key)", message: "expected \"#RRGGBB\""))
                continue
            }
            colors[theme.light, default: [:]][token] = color
        }
        return ThemeEdits(colors)
    }
}
