import Foundation

extension GhosttyConfig {
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
        return normalizedConditionalThemeValue(from: rawThemeValue)
    }

    private static func normalizedConditionalThemeValue(from rawThemeValue: String) -> String? {
        var lightTheme: String?
        var darkTheme: String?

        for token in rawThemeValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                if lightTheme == nil { lightTheme = value }
            case "dark":
                if darkTheme == nil { darkTheme = value }
            default:
                continue
            }
        }

        switch (lightTheme, darkTheme) {
        case let (light?, nil):
            return "light:\(light),dark:\(light)"
        case let (nil, dark?):
            return "light:\(dark),dark:\(dark)"
        default:
            return nil
        }
    }
}
