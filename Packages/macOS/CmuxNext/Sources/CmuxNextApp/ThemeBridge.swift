import AppKit
import CmuxNextDesign
import CmuxNextTerminal

/// Feeds the Ghostty config's colors into `ThemeStore`, at launch and after
/// every config change (reload keybind, Reload Configuration action,
/// light/dark conditional themes), so all chrome follows the terminal theme.
enum ThemeBridge {
    static func start() {
        let runtime = GhosttyRuntime.shared
        let previous = runtime.onConfigChange
        runtime.onConfigChange = {
            previous?()
            apply(runtime)
        }
        apply(runtime)
    }

    private static func apply(_ runtime: GhosttyRuntime) {
        guard let colors = runtime.themeColors else { return }
        ThemeStore.shared.apply(input(colors))
    }

    static func input(_ colors: GhosttyThemeColors) -> ThemeInput {
        func rgb(_ c: GhosttyThemeColors.RGB) -> ThemeRGB { ThemeRGB(r: c.r, g: c.g, b: c.b) }
        return ThemeInput(
            background: rgb(colors.background),
            foreground: rgb(colors.foreground),
            palette: colors.palette.map(rgb),
            selectionBackground: colors.selectionBackground.map(rgb),
            selectionForeground: colors.selectionForeground.map(rgb),
            backgroundOpacity: colors.backgroundOpacity,
            backgroundBlur: colors.backgroundBlur
        )
    }
}
