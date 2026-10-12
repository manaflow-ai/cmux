import AppKit
import CmuxNextDesign
import CmuxNextTerminal

/// Feeds the Ghostty config's colors into `ThemeStore`, at launch and after
/// every config change (reload keybind, Reload Configuration action,
/// light/dark conditional themes), so all chrome follows the terminal theme.
/// cmux.json's window background (`GhosttyRuntime.backgroundOverride`) is
/// already in that config; resolving it again here is a no-op that keeps
/// the tokens right for colors read any other way.
enum ThemeBridge {
    /// A theme's own accent by theme name: its `<theme>/accent` edit from launch, then (once
    /// `ThemeCoordinator` adds the theme catalog) its file's `# cmux-accent`.
    static var accent: @MainActor (String) -> ThemeRGB? = { edited($0) }

    /// A theme's `<theme>/accent` edit.
    static func edited(_ name: String) -> ThemeRGB? {
        GhosttyRuntime.themeEdits.accent(for: name).flatMap { ThemeRGB(cssHex: $0) }
    }

    static func start() {
        let runtime = GhosttyRuntime.shared
        let previous = runtime.onConfigChange
        runtime.onConfigChange = {
            previous?()
            apply(runtime)
        }
        apply(runtime)
    }

    /// Applies the config's colors again, for a change only cmux reads (a theme's accent).
    static func refresh() { apply(GhosttyRuntime.shared) }

    private static func apply(_ runtime: GhosttyRuntime) {
        guard let colors = runtime.themeColors else { return }
        ThemeStore.shared.apply(input(colors, background: GhosttyRuntime.backgroundOverride,
                                      accent: GhosttyRuntime.themeName.flatMap(accent)))
    }

    /// The theme input for `colors`, with `background` (cmux.json's
    /// `appearance.backgroundOpacity` and `appearance.backgroundBlur`) over
    /// their opacity and blur: the one resolved value `WindowBackdrop`
    /// reads.
    static func input(_ colors: GhosttyThemeColors, background: WindowBackgroundOverride = WindowBackgroundOverride(),
                      accent: ThemeRGB? = nil) -> ThemeInput {
        func rgb(_ c: GhosttyThemeColors.RGB) -> ThemeRGB { ThemeRGB(r: c.r, g: c.g, b: c.b) }
        let resolved = background.resolved(backgroundOpacity: colors.backgroundOpacity, backgroundBlur: colors.backgroundBlur)
        var input = ThemeInput(
            background: rgb(colors.background),
            foreground: rgb(colors.foreground),
            palette: colors.palette.map(rgb),
            selectionBackground: colors.selectionBackground.map(rgb),
            selectionForeground: colors.selectionForeground.map(rgb),
            cursor: colors.cursor.map(rgb),
            backgroundOpacity: resolved.backgroundOpacity,
            backgroundBlur: resolved.backgroundBlur
        )
        input.accentColor = accent
        return input
    }
}
