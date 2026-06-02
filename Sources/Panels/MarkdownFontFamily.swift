import Foundation

/// Body prose font for the markdown viewer, chosen from the user's installed
/// fonts (including custom fonts).
///
/// The stored value is a font-family name; an empty string is the System
/// default (the GitHub stack), which clears the inline override. The chosen
/// family is applied as an inline `font-family` on the content element
/// (mirroring the theme injection). Code blocks keep their own monospace stack
/// from `github-markdown.css`.
enum MarkdownFontFamily {
    /// UserDefaults / cmux.json key (`markdown.fontFamily`).
    static let key = "markdown.fontFamily"
    /// Sentinel value for the System default (inherits the GitHub stack).
    static let systemDefault = ""

    /// Normalizes user/config input before persisting or applying it. Newlines
    /// collapse to spaces so a malformed cmux.json value cannot produce invalid
    /// multiline CSS.
    static func normalized(_ family: String) -> String {
        family
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The CSS `font-family` to apply, or `nil` for the System default. The
    /// family name is quoted so multi-word names resolve correctly.
    static func cssValue(for family: String) -> String? {
        let trimmed = normalized(family)
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The persistent default font family, honoring `markdown.fontFamily` from
    /// UserDefaults / cmux.json and falling back to the System default.
    static func resolvedDefault(defaults: UserDefaults = .standard) -> String {
        normalized(defaults.string(forKey: key) ?? systemDefault)
    }

    /// Persists `family` as the default `markdown.fontFamily` so new viewers
    /// start with it. An empty family removes the override.
    static func setDefault(_ family: String, defaults: UserDefaults = .standard) {
        let trimmed = normalized(family)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    /// Installed font families available to choose, sorted case-insensitively
    /// and excluding hidden (dot-prefixed) system fonts.
    ///
    /// Loaded off the main thread (font enumeration can take noticeable time on
    /// machines with many installed fonts) and cached, so the typography popover
    /// opens instantly and the list fills in shortly after.
    static func availableFamilies() async -> [String] {
        await familyCache.families()
    }

    private static let familyCache = MarkdownFontFamilyCache()
}
