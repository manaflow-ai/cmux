/// The immutable result consumed by chrome views.
public struct ChromePalette: Sendable, Equatable {
    /// The selected built-in theme.
    public let theme: ChromeThemeID
    /// The concrete light or dark variant resolved for this palette.
    public let colorScheme: ChromeColorScheme
    /// The complete semantic token map after overrides and accessibility repair.
    public let tokens: [ChromeToken: ChromeColor]

    /// Creates an immutable palette snapshot.
    ///
    /// - Parameters:
    ///   - theme: Theme identifier represented by the snapshot.
    ///   - colorScheme: Concrete light or dark variant.
    ///   - tokens: Token values. Missing values use deterministic role fallbacks.
    public init(
        theme: ChromeThemeID,
        colorScheme: ChromeColorScheme,
        tokens: [ChromeToken: ChromeColor]
    ) {
        self.theme = theme
        self.colorScheme = colorScheme
        self.tokens = tokens
    }

    /// Returns the color for `token`, using a deterministic fallback for an
    /// incomplete custom palette.
    public subscript(_ token: ChromeToken) -> ChromeColor {
        // Every built-in palette is total. Keeping a deterministic fallback
        // makes malformed/incomplete custom construction safe for callers.
        tokens[token] ?? Self.fallbackColor(for: token, scheme: colorScheme)
    }

    /// Primary interactive accent.
    public var accent: ChromeColor { self[.accent] }
    /// Low-emphasis accent wash.
    public var accentSoft: ChromeColor { self[.accentSoft] }
    /// Base chrome surface.
    public var surface: ChromeColor { self[.surface] }
    /// Elevated chrome surface.
    public var surfaceRaised: ChromeColor { self[.surfaceRaised] }
    /// Selected-row or selected-tab surface.
    public var surfaceSelected: ChromeColor { self[.surfaceSelected] }
    /// Pointer-hover surface.
    public var surfaceHover: ChromeColor { self[.surfaceHover] }
    /// Highest-emphasis chrome text.
    public var textPrimary: ChromeColor { self[.textPrimary] }
    /// Supporting chrome text.
    public var textSecondary: ChromeColor { self[.textSecondary] }
    /// Lowest-emphasis chrome text.
    public var textTertiary: ChromeColor { self[.textTertiary] }
    /// Foreground chosen for text rendered on the selected-surface token.
    ///
    /// A single ``textPrimary`` color cannot be guaranteed to contrast with
    /// both a very light base surface and a saturated selected surface. Views
    /// that render text on selection should use this derived role instead of
    /// guessing black or white locally.
    public var textOnSelected: ChromeColor {
        let primary = textPrimary
        return primary.contrastRatio(with: surfaceSelected, underlying: opaqueSurface) >= 4.5
            ? primary
            : Self.readableTextColor(on: surfaceSelected, underlying: opaqueSurface)
    }

    /// Foreground chosen for text rendered on the accent token.
    public var textOnAccent: ChromeColor {
        let primary = textPrimary
        return primary.contrastRatio(with: accent, underlying: opaqueSurface) >= 4.5
            ? primary
            : Self.readableTextColor(on: accent, underlying: opaqueSurface)
    }

    /// Returns a foreground suitable for text drawn over an arbitrary token.
    ///
    /// This is used by small chrome controls whose fill can be customized
    /// independently of the text roles (for example, status glyphs and
    /// notification badges). The selected palette's opaque surface is used
    /// when the background token is translucent, so the result reflects the
    /// color that is actually visible to the user.
    public func readableForeground(
        for background: ChromeColor,
        minimumContrast: Double = 4.5
    ) -> ChromeColor {
        let preferred = textPrimary
        return preferred.contrastRatio(with: background, underlying: opaqueSurface) >= minimumContrast
            ? preferred
            : Self.readableTextColor(on: background, underlying: opaqueSurface)
    }
    /// Strong divider and outline color.
    public var border: ChromeColor { self[.border] }
    /// Low-emphasis divider and outline color.
    public var borderSubtle: ChromeColor { self[.borderSubtle] }

    /// Neutral or idle agent state color.
    public var agentIdle: ChromeColor { self[.agentIdle] }
    /// In-progress agent state color.
    public var agentWorking: ChromeColor { self[.agentWorking] }
    /// Successful agent state color.
    public var agentSuccess: ChromeColor { self[.agentSuccess] }
    /// Attention or warning agent state color.
    public var agentWarning: ChromeColor { self[.agentWarning] }
    /// Failed or error agent state color.
    public var agentError: ChromeColor { self[.agentError] }

    /// Returns whether `token` differs from the built-in default palette.
    ///
    /// Non-default themes are customized by definition. For the default theme,
    /// this compares the resolved value with the matching built-in light or dark
    /// variant so chrome that historically inherited a terminal backdrop can
    /// preserve that rendering until its relevant token is explicitly changed.
    public func isCustomized(_ token: ChromeToken) -> Bool {
        guard theme == .default else { return true }
        let builtIn = Self.defaultTokens(for: colorScheme)[token]
            ?? Self.fallbackColor(for: token, scheme: colorScheme)
        return self[token] != builtIn
    }

    /// Resolves a theme variant and overlays validated user values.
    ///
    /// `appearanceMode` is the existing app-level System/Light/Dark setting;
    /// `effectiveSystemScheme` is only consulted for `.system`.
    public static func resolve(
        theme: ChromeThemeID,
        appearanceMode: AppearanceMode,
        effectiveSystemScheme: ChromeColorScheme,
        overrides: ChromeTokenOverrides = .empty
    ) -> ChromePalette {
        let scheme: ChromeColorScheme
        switch appearanceMode {
        case .light:
            scheme = .light
        case .dark:
            scheme = .dark
        case .system:
            scheme = effectiveSystemScheme
        }

        var resolved = baseTokens(for: theme, scheme: scheme)
        for (token, color) in overrides.values {
            resolved[token] = color
        }
        resolved = ensureAccessibleText(resolved, scheme: scheme)
        return ChromePalette(theme: theme, colorScheme: scheme, tokens: resolved)
    }

    /// Convenience for clients that already resolved the concrete variant.
    public static func resolve(
        theme: ChromeThemeID,
        colorScheme: ChromeColorScheme,
        overrides: ChromeTokenOverrides = .empty
    ) -> ChromePalette {
        resolve(
            theme: theme,
            appearanceMode: colorScheme == .dark ? .dark : .light,
            effectiveSystemScheme: colorScheme,
            overrides: overrides
        )
    }

    /// Returns the built-in colors without applying user overrides. Useful for
    /// previews and tests that want to compare a theme's two variants.
    public static func builtIn(
        theme: ChromeThemeID,
        colorScheme: ChromeColorScheme
    ) -> ChromePalette {
        if theme == .default {
            return ChromePalette(
                theme: theme,
                colorScheme: colorScheme,
                tokens: defaultTokens(for: colorScheme)
            )
        }
        let tokens = ensureAccessibleText(baseTokens(for: theme, scheme: colorScheme), scheme: colorScheme)
        return ChromePalette(theme: theme, colorScheme: colorScheme, tokens: tokens)
    }

    private static let defaultLightTokens = ensureAccessibleText(
        baseTokens(for: .default, scheme: .light),
        scheme: .light
    )
    private static let defaultDarkTokens = ensureAccessibleText(
        baseTokens(for: .default, scheme: .dark),
        scheme: .dark
    )

    private static func defaultTokens(
        for scheme: ChromeColorScheme
    ) -> [ChromeToken: ChromeColor] {
        scheme == .dark ? defaultDarkTokens : defaultLightTokens
    }

    private static func baseTokens(
        for theme: ChromeThemeID,
        scheme: ChromeColorScheme
    ) -> [ChromeToken: ChromeColor] {
        switch (theme, scheme) {
        case (.default, .light):
            return make(
                accent: "#0088FF", accentSoft: "#E6F2FF",
                surface: "#F5F5F7", raised: "#FFFFFF", selected: "#0088FF", hover: "#EAF3FF",
                primary: "#1D1D1F", secondary: "#636366", tertiary: "#8E8E93",
                border: "#D1D1D6", subtleBorder: "#E5E5EA",
                idle: "#8E8E93", working: "#007AFF", success: "#34C759", warning: "#FF9500", error: "#FF3B30"
            )
        case (.default, .dark):
            return make(
                accent: "#0091FF", accentSoft: "#18344D",
                surface: "#1C1C1E", raised: "#2C2C2E", selected: "#0091FF", hover: "#20384D",
                primary: "#F5F5F7", secondary: "#AEAEB2", tertiary: "#8E8E93",
                border: "#48484A", subtleBorder: "#38383A",
                idle: "#8E8E93", working: "#64B5F6", success: "#30D158", warning: "#FF9F0A", error: "#FF453A"
            )
        case (.catppuccin, .light):
            return make(
                accent: "#1E66F5", accentSoft: "#DCE7FF",
                surface: "#EFF1F5", raised: "#E6E9EF", selected: "#1E66F5", hover: "#DCE7FF",
                primary: "#4C4F69", secondary: "#6C6F85", tertiary: "#8C8FA1",
                border: "#CCD0DA", subtleBorder: "#DCE0E8",
                idle: "#8C8FA1", working: "#1E66F5", success: "#40A02B", warning: "#DF8E1D", error: "#D20F39"
            )
        case (.catppuccin, .dark):
            return make(
                accent: "#89B4FA", accentSoft: "#263A59",
                surface: "#1E1E2E", raised: "#313244", selected: "#89B4FA", hover: "#293750",
                primary: "#CDD6F4", secondary: "#A6ADC8", tertiary: "#7F849C",
                border: "#585B70", subtleBorder: "#45475A",
                idle: "#7F849C", working: "#89B4FA", success: "#A6E3A1", warning: "#F9E2AF", error: "#F38BA8"
            )
        case (.gruvbox, .light):
            return make(
                accent: "#458588", accentSoft: "#DDEBE8",
                surface: "#FBF1C7", raised: "#F2E5BC", selected: "#458588", hover: "#E6E1C3",
                primary: "#3C3836", secondary: "#665C54", tertiary: "#928374",
                border: "#D5C4A1", subtleBorder: "#E1D6B8",
                idle: "#928374", working: "#076678", success: "#79740E", warning: "#B57614", error: "#9D0006"
            )
        case (.gruvbox, .dark):
            return make(
                accent: "#83A598", accentSoft: "#304A4A",
                surface: "#282828", raised: "#3C3836", selected: "#83A598", hover: "#344342",
                primary: "#EBDBB2", secondary: "#D5C4A1", tertiary: "#A89984",
                border: "#665C54", subtleBorder: "#504945",
                idle: "#A89984", working: "#83A598", success: "#B8BB26", warning: "#FABD2F", error: "#FB4934"
            )
        case (.solarized, .light):
            return make(
                accent: "#268BD2", accentSoft: "#D7EAF7",
                surface: "#FDF6E3", raised: "#EEE8D5", selected: "#268BD2", hover: "#E1F0F8",
                primary: "#073642", secondary: "#586E75", tertiary: "#839496",
                border: "#93A1A1", subtleBorder: "#D4D9D5",
                idle: "#839496", working: "#268BD2", success: "#859900", warning: "#B58900", error: "#DC322F"
            )
        case (.solarized, .dark):
            return make(
                accent: "#268BD2", accentSoft: "#123B53",
                surface: "#002B36", raised: "#073642", selected: "#268BD2", hover: "#10445A",
                primary: "#FDF6E3", secondary: "#EEE8D5", tertiary: "#93A1A1",
                border: "#586E75", subtleBorder: "#34515A",
                idle: "#839496", working: "#268BD2", success: "#859900", warning: "#B58900", error: "#DC322F"
            )
        }
    }

    private static func make(
        accent: String, accentSoft: String,
        surface: String, raised: String, selected: String, hover: String,
        primary: String, secondary: String, tertiary: String,
        border: String, subtleBorder: String,
        idle: String, working: String, success: String, warning: String, error: String
    ) -> [ChromeToken: ChromeColor] {
        let values: [(ChromeToken, String)] = [
            (.accent, accent), (.accentSoft, accentSoft),
            (.surface, surface), (.surfaceRaised, raised), (.surfaceSelected, selected), (.surfaceHover, hover),
            (.textPrimary, primary), (.textSecondary, secondary), (.textTertiary, tertiary),
            (.border, border), (.borderSubtle, subtleBorder),
            (.agentIdle, idle), (.agentWorking, working), (.agentSuccess, success),
            (.agentWarning, warning), (.agentError, error),
        ]
        return Dictionary(uniqueKeysWithValues: values.compactMap { token, raw in
            guard let color = ChromeColor(hex: raw) else { return nil }
            return (token, color)
        })
    }

    private static func ensureAccessibleText(
        _ tokens: [ChromeToken: ChromeColor],
        scheme: ChromeColorScheme
    ) -> [ChromeToken: ChromeColor] {
        var result = tokens
        let surface = result[.surface] ?? fallbackColor(for: .surface, scheme: scheme)
        let underlying = scheme == .dark ? ChromeColor.black : .white
        let readable = readableTextColor(on: surface, underlying: underlying)
        if (result[.textPrimary] ?? readable).contrastRatio(with: surface, underlying: underlying) < 4.5 {
            result[.textPrimary] = readable
        }
        if (result[.textSecondary] ?? readable).contrastRatio(with: surface, underlying: underlying) < 3.0 {
            // Secondary text is commonly rendered at reduced opacity by the
            // platform. Store an opaque fallback here so compositing cannot
            // make an otherwise valid override illegible.
            result[.textSecondary] = readable
        }
        result[.textTertiary] = colorMeetingContrast(
            result[.textTertiary] ?? readable,
            on: surface,
            underlying: underlying,
            minimumRatio: 3
        )
        for token in [
            ChromeToken.agentIdle,
            .agentWorking,
            .agentSuccess,
            .agentWarning,
            .agentError,
        ] {
            let candidate = result[token] ?? fallbackColor(for: token, scheme: scheme)
            result[token] = colorMeetingContrast(
                candidate,
                on: surface,
                underlying: underlying,
                minimumRatio: 3
            )
        }
        return result
    }

    /// Returns the nearest sRGB blend toward black or white that satisfies
    /// `minimumRatio`, retaining the candidate hue as much as possible.
    private static func colorMeetingContrast(
        _ candidate: ChromeColor,
        on background: ChromeColor,
        underlying: ChromeColor,
        minimumRatio: Double
    ) -> ChromeColor {
        guard candidate.contrastRatio(with: background, underlying: underlying) < minimumRatio else {
            return candidate
        }
        let target = readableTextColor(on: background, underlying: underlying)
        var failingAmount = 0.0
        var passingAmount = 1.0
        var passingColor = target
        for _ in 0..<20 {
            let amount = (failingAmount + passingAmount) / 2
            let mixed = ChromeColor(
                red: candidate.red * (1 - amount) + target.red * amount,
                green: candidate.green * (1 - amount) + target.green * amount,
                blue: candidate.blue * (1 - amount) + target.blue * amount,
                alpha: candidate.alpha * (1 - amount) + target.alpha * amount
            )
            if mixed.contrastRatio(with: background, underlying: underlying) >= minimumRatio {
                passingAmount = amount
                passingColor = mixed
            } else {
                failingAmount = amount
            }
        }
        return passingColor
    }

    private static func readableTextColor(
        on background: ChromeColor,
        underlying: ChromeColor? = nil
    ) -> ChromeColor {
        let blackContrast = ChromeColor.black.contrastRatio(with: background, underlying: underlying)
        let whiteContrast = ChromeColor.white.contrastRatio(with: background, underlying: underlying)
        return whiteContrast >= blackContrast ? .white : .black
    }

    private var opaqueSurface: ChromeColor {
        surface.opaqueColor(over: colorScheme == .dark ? .black : .white)
    }

    private static func fallbackColor(for token: ChromeToken, scheme: ChromeColorScheme) -> ChromeColor {
        switch token {
        case .surface, .surfaceRaised, .surfaceHover, .accentSoft:
            return scheme == .dark ? ChromeColor(red: 0.12, green: 0.12, blue: 0.14) : ChromeColor(red: 0.96, green: 0.96, blue: 0.97)
        case .surfaceSelected, .accent, .agentWorking:
            return scheme == .dark ? ChromeColor(red: 0, green: 0.57, blue: 1) : ChromeColor(red: 0, green: 0.53, blue: 1)
        case .textPrimary, .textSecondary, .textTertiary, .border, .borderSubtle, .agentIdle:
            return scheme == .dark ? ChromeColor.white : ChromeColor.black
        case .agentSuccess:
            return scheme == .dark ? ChromeColor(red: 0.19, green: 0.82, blue: 0.35) : ChromeColor(red: 0.2, green: 0.78, blue: 0.35)
        case .agentWarning:
            return scheme == .dark ? ChromeColor(red: 1, green: 0.62, blue: 0.04) : ChromeColor(red: 1, green: 0.58, blue: 0)
        case .agentError:
            return scheme == .dark ? ChromeColor(red: 1, green: 0.27, blue: 0.23) : ChromeColor(red: 1, green: 0.23, blue: 0.19)
        }
    }
}
