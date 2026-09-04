import Foundation

extension GhosttyConfig {
    // Shared by the primary config parser and this repair extension. It stays
    // internal because Swift's `private` members cannot be referenced by a
    // same-type extension in another file; callers outside this module do not
    // need the tokenizer itself.
    /// Splits a raw theme directive into its first light, dark, and fallback values.
    ///
    /// - Parameter rawThemeValue: The comma-separated value from a `theme` directive.
    /// - Returns: The first recognized value for each conditional side and fallback.
    static func conditionalThemeComponents(
        from rawThemeValue: String
    ) -> (light: String?, dark: String?, fallback: String?) {
        var fallbackTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawThemeValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                if fallbackTheme == nil {
                    fallbackTheme = entry
                }
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                if lightTheme == nil {
                    lightTheme = value
                }
            case "dark":
                if darkTheme == nil {
                    darkTheme = value
                }
            default:
                if fallbackTheme == nil {
                    fallbackTheme = value
                }
            }
        }

        return (light: lightTheme, dark: darkTheme, fallback: fallbackTheme)
    }

    /// Returns a valid two-sided theme value for a stale cmux-managed override.
    ///
    /// Ghostty requires both `light:` and `dark:` entries in a conditional theme
    /// value. Older cmux versions wrote only the selected side, so this helper
    /// repairs that form in memory while the application loads its managed
    /// configuration. It deliberately ignores unmarked user configuration and
    /// leaves already-valid pairs and plain theme values unchanged.
    ///
    /// - Parameter contents: The complete contents of a cmux-managed config file.
    /// - Returns: A normalized `light:…,dark:…` value when the managed block is
    ///   single-sided, otherwise `nil`.
    public static func normalizedCmuxManagedThemeValue(in contents: String) -> String? {
        var insideManagedBlock = false
        var rawThemeValue: String?

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmed {
            case "# cmux themes start":
                insideManagedBlock = true
            case "# cmux themes end":
                insideManagedBlock = false
            default:
                guard insideManagedBlock else { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "theme" else {
                    continue
                }

                let value = parts[1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !value.isEmpty {
                    rawThemeValue = value
                }
            }
        }

        guard let rawThemeValue else { return nil }
        let components = conditionalThemeComponents(from: rawThemeValue)
        switch (components.light, components.dark) {
        case let (light?, nil):
            return "light:\(light),dark:\(light)"
        case let (nil, dark?):
            return "light:\(dark),dark:\(dark)"
        default:
            return nil
        }
    }
}
