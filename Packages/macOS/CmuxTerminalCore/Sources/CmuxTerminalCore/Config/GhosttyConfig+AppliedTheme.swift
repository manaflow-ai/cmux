import Foundation

extension GhosttyConfig {
    /// The concrete theme name Ghostty actually applies for `preferredColorScheme`,
    /// or `nil` when a conditional `theme` value names no theme for that appearance
    /// side and carries no unconditional base.
    ///
    /// Unlike ``GhosttyConfig/resolveThemeName(from:preferredColorScheme:)`` this
    /// performs **no cross-side fallback**: `light:X` (with no `dark:` token)
    /// resolves to `X` for `.light` and to `nil` for `.dark`. That matches how
    /// Ghostty resolves a conditional `theme` directive — a side applies only to its
    /// own appearance — and how the terminal-surface override is gated (see
    /// ``GhosttyConfig/explicitConditionalThemeName(from:preferredColorScheme:)``).
    /// An unconditional (plain) `theme = X` still applies in every scheme.
    ///
    /// cmux paints the terminal background from its host layer
    /// (`macos-background-from-layer = true`) using the color this resolves to,
    /// while Ghostty renders the foreground text from the surface config. When the
    /// host-layer resolver cross-side fell back to the opposite appearance's theme,
    /// cmux painted a light theme's near-white background under Ghostty's default
    /// near-white foreground in the mismatched appearance — the unreadable
    /// white-on-white regression in
    /// https://github.com/manaflow-ai/cmux/issues/6411. Resolving the same way the
    /// surface does keeps the host background and terminal foreground consistent.
    public static func appliedThemeName(
        from rawThemeValue: String,
        preferredColorScheme: ColorSchemePreference
    ) -> String? {
        var unconditionalTheme: String?
        var lightTheme: String?
        var darkTheme: String?

        for token in rawThemeValue.split(separator: ",").map(String.init) {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count != 2 {
                if unconditionalTheme == nil { unconditionalTheme = entry }
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "light":
                if lightTheme == nil { lightTheme = value }
            case "dark":
                if darkTheme == nil { darkTheme = value }
            default:
                if unconditionalTheme == nil { unconditionalTheme = value }
            }
        }

        switch preferredColorScheme {
        case .light:
            if let lightTheme { return lightTheme }
        case .dark:
            if let darkTheme { return darkTheme }
        }

        // Fall back only to an unconditional base — never to the opposite
        // appearance's side (that is the #6411 white-on-white regression).
        return unconditionalTheme
    }
}
