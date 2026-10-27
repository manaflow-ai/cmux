public import CmuxTheme

extension WindowPictureMeta {
    /// The theme's fingerprint (``theme``): `input`'s fields and `app`'s tokens, each named and in a fixed order, so
    /// the same theme gives the same digest in every launch.
    public static func themeFingerprint(input: ThemeInput, app: AppTheme) -> String {
        fingerprint(themeParts(input: input, app: app))
    }

    static func themeParts(input: ThemeInput, app: AppTheme) -> [String] {
        func color(_ rgb: ThemeRGB?) -> String { rgb.map(\.description) ?? "-" }
        var parts = [
            "input",
            "background=\(color(input.background))",
            "foreground=\(color(input.foreground))",
            "palette=\(input.palette.count)",
        ]
        parts += input.palette.map { color($0) }
        parts += [
            "selectionBackground=\(color(input.selectionBackground))",
            "selectionForeground=\(color(input.selectionForeground))",
            "cursor=\(color(input.cursor))",
            "opacity=\(input.backgroundOpacity)",
            "blur=\(input.backgroundBlur)",
            "accent=\(input.accent.rawValue)",
            "accentColor=\(color(input.accentColor))",
            "app",
            "isDark=\(app.isDark)",
        ]
        parts += AppTheme.Token.allCases.map { "\($0.rawValue)=\(color(app[$0]))" }
        return parts
    }
}
