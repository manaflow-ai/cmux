import Foundation

/// A Ghostty theme spec as the `theme` config key takes it: one theme name
/// (`Nord`) or a light/dark pair (`light:Rose Pine Dawn,dark:Rose Pine`).
/// Rooms, workspaces and terminals store it as text; the App resolves it to
/// colors the same way the Ghostty config resolves `theme`.
public nonisolated struct ThemeSpec: Hashable, Sendable, CustomStringConvertible {
    /// The spec as written (trimmed).
    public let raw: String
    /// Theme name used while the system appearance is light.
    public let light: String
    /// Theme name used while the system appearance is dark.
    public let dark: String

    /// Longest accepted spec; longer text is refused.
    public static let maximumLength = 200

    /// Parses `raw`. Nil for empty text, text over `maximumLength`, a part
    /// with an unknown prefix, or characters that could start another
    /// config line (control characters, `#`, `=`, `"`).
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumLength,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !"#=\"".unicodeScalars.contains($0) })
        else { return nil }
        var light: String?
        var dark: String?
        var plain: String?
        for part in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let text = part.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            if let name = Self.value(of: text, prefix: "light:") {
                light = name
            } else if let name = Self.value(of: text, prefix: "dark:") {
                dark = name
            } else if plain == nil, !text.contains(":") {
                plain = text
            } else {
                return nil
            }
        }
        guard let resolvedLight = light ?? dark ?? plain, let resolvedDark = dark ?? light ?? plain else { return nil }
        self.raw = trimmed
        self.light = resolvedLight
        self.dark = resolvedDark
    }

    /// True for a light/dark pair naming two different themes.
    public var isConditional: Bool { light != dark }

    /// The theme name for the current system appearance.
    public func name(isDark: Bool) -> String { isDark ? dark : light }

    /// The Ghostty config line that applies this spec to one variant, so a
    /// resolved config never depends on the conditional state.
    public func configLine(isDark: Bool) -> String { "theme = \(name(isDark: isDark))" }

    public var description: String { raw }

    private static func value(of text: String, prefix: String) -> String? {
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        let name = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
