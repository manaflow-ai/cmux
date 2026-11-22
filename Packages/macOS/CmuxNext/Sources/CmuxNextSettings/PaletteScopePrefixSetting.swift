/// `palette.scopes.<scope>.prefix` in cmux.json: the one character that
/// enters a built-in palette scope when typed into an empty query
/// (plans/cmux-next/palette-scopes.md, decision D-PS4). "none" turns the
/// prefix off. A prefix the user assigns wins over a default: a built-in
/// scope that had it by default loses it.
public nonisolated struct PaletteScopePrefixes: Sendable, Equatable {
    /// User assignments by scope id: a character, or nil for "none". Scopes
    /// not listed keep their default.
    public var assigned: [String: String?] = [:]

    public init(assigned: [String: String?] = [:]) {
        self.assigned = assigned
    }

    /// The built-in scopes with a prefix setting, in Settings order, with
    /// their default prefixes.
    public static let defaults: [(scope: String, prefix: String)] = [
        ("tabs", "@"), ("workspaces", "#"), ("commands", ">"), ("settings", ","), ("scopes", "?"),
    ]

    /// Characters a prefix may be. Letters, digits and spaces are never
    /// prefixes: typing a word must never enter a scope.
    public static let characters = ["@", "#", ">", ",", "?", "!", "/", ";", ":", "%", "&", "+", "=", "~", "$", "^", "*", "."]
    public static let noneValue = "none"

    public static func path(_ scope: String) -> [String] { ["palette", "scopes", scope, "prefix"] }

    /// A missing key keeps the default with no diagnostic; a bad value keeps
    /// the default and adds a diagnostic.
    static func parse(_ root: JSONValue) -> (PaletteScopePrefixes, [SettingsDiagnostic]) {
        var prefixes = PaletteScopePrefixes()
        var diagnostics: [SettingsDiagnostic] = []
        for (scope, _) in defaults {
            guard let value = root.value(at: path(scope)) else { continue }
            if let text = value.stringValue, text == noneValue {
                prefixes.assigned[scope] = .some(nil)
            } else if let text = value.stringValue, characters.contains(text) {
                prefixes.assigned[scope] = .some(text)
            } else {
                diagnostics.append(SettingsDiagnostic(
                    kind: .invalidValue, path: path(scope).joined(separator: "."),
                    message: "expected one punctuation character (\(characters.joined(separator: " "))) or \"none\""))
            }
        }
        return (prefixes, diagnostics)
    }
}
