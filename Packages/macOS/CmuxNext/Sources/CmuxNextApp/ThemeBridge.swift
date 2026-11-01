import AppKit
import CmuxNextDesign
import CmuxNextTerminal

/// Feeds the Ghostty config's colors into `ThemeStore`, at launch and after
/// every config change (reload keybind, Reload Configuration action,
/// light/dark conditional themes), so all chrome follows the terminal theme (or `appearance.appTheme`),
/// and its unfocused-split dim into `DesignSettings`, so panes dim as in Ghostty.
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

    /// Feeds `store` (the app's, from the composition root) the Ghostty config now and on every reload.
    static func start(store: ThemeStore) {
        let runtime = GhosttyRuntime.shared
        let previous = runtime.onConfigChange
        runtime.onConfigChange = { [weak store] in
            previous?()
            if let store { apply(runtime, to: store) }
        }
        apply(runtime, to: store)
    }

    /// Applies the config's colors again, for a change only cmux reads (a theme's accent).
    static func refresh(store: ThemeStore) { apply(GhosttyRuntime.shared, to: store) }

    /// Repaints with cmux.json's window background over the config files' own opacity and blur,
    /// ahead of the config reload that brings the terminals along (an Opacity slider step).
    static func repaintBackground(store: ThemeStore) {
        let resolved = GhosttyRuntime.backgroundOverride.resolved(
            backgroundOpacity: GhosttyConfigBackground.loaded.opacity, backgroundBlur: GhosttyConfigBackground.loaded.blur)
        store.applyBackground(opacity: resolved.backgroundOpacity, blur: resolved.backgroundBlur)
    }

    private static func apply(_ runtime: GhosttyRuntime, to store: ThemeStore) {
        let dim = unfocusedPaneDim(runtime.unfocusedSplit)
        if DesignSettings.shared.unfocusedPaneDim != dim { DesignSettings.shared.unfocusedPaneDim = dim }
        guard let colors = runtime.themeColors else { return }
        store.apply(input(colors, background: GhosttyRuntime.backgroundOverride,
                                      accent: GhosttyRuntime.themeName.flatMap(accent)))
    }

    /// The pane dim for the config's `unfocused-split-opacity` and `unfocused-split-fill`.
    static func unfocusedPaneDim(_ split: GhosttyUnfocusedSplit) -> UnfocusedPaneDim {
        UnfocusedPaneDim(unfocusedSplitOpacity: split.opacity, fill: split.fill.map { ThemeRGB(r: $0.r, g: $0.g, b: $0.b) })
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
