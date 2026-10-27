import CmuxNextDesign
import Foundation
import GhosttyNextKit

/// cmux-next's default terminal theme, which differs from Ghostty's: Ghostty's
/// bundled "Apple System Colors" in dark mode and "Apple System Colors Light"
/// in light mode, following the macOS appearance live. It is loaded before
/// the user's Ghostty config files, so their own `theme` or colors win, and
/// everyone without one gets it.
extension GhosttyRuntime {
    /// Theme file names in Ghostty's bundled `themes` folder.
    public nonisolated static let defaultDarkThemeName = "Apple System Colors"
    public nonisolated static let defaultLightThemeName = "Apple System Colors Light"

    /// The default as a Ghostty theme spec.
    public nonisolated static var defaultThemeSpec: String {
        "light:\(defaultLightThemeName),dark:\(defaultDarkThemeName)"
    }

    /// Loads the default before the user's files.
    /// `themesFolder` names the themes by absolute path (tests: Ghostty
    /// reads its resources folder once, at `ghostty_init`).
    nonisolated static func loadThemeDefault(into config: ghostty_config_t, themesFolder: URL? = nil) {
        let spec = themesFolder.map { "light:\($0.appending(path: defaultLightThemeName).path),dark:\($0.appending(path: defaultDarkThemeName).path)" }
        let line = "theme = \(spec ?? defaultThemeSpec)"
        // SAFETY: the caller passes a live config.
        unsafe loadConfigLine(line, into: config, source: "cmux-next")
    }

    /// The colors a user config made of `text` (Ghostty config lines)
    /// resolves to with the default loaded first, for tests. Ghostty applies
    /// a light/dark spec's variant only through an app's color scheme; a
    /// bare config resolves the light variant.
    static func themeColors(configText text: String, themesFolder: URL? = nil) -> GhosttyThemeColors? {
        // SAFETY: withScratchConfig's handle is live for each closure's call and stays in it.
        let colors = unsafe withScratchConfig(load: {
            // SAFETY: as above.
            unsafe loadThemeDefault(into: $0, themesFolder: themesFolder)
            // SAFETY: as above.
            unsafe loadConfigLine(text, into: $0, source: "test")
        }, read: {
            // SAFETY: as above.
            unsafe themeColors(of: $0, backgroundOpacity: 1)
        })
        return colors ?? nil
    }
}

extension GhosttyRuntime {
    /// Gives `view`'s new surface the current scheme and every later change.
    func registerColorScheme(of view: TerminalSurfaceView) {
        colorSchemeSurfaces.add(view)
        view.applyColorScheme(dark: isDark, animated: false)
    }

    /// Gives every surface the color transition in effect now, before an app-wide config call
    /// (`ghostty_app_update_config`) that can change their colors.
    func applyColorTransitionToSurfaces() {
        for view in colorSchemeSurfaces.allObjects { view.applyColorTransition() }
    }
}

extension TerminalSurfaceView {
    /// `ghostty_surface_set_color_scheme` (ghostty.h:1573) on the live surface.
    /// `animated` false: a new surface shows its first colors at once.
    func applyColorScheme(dark: Bool, animated: Bool = true) {
        guard let surface else { return }
        colorSchemeIsDark = dark
        applyColorTransition(animated: animated)
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        unsafe ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    /// Gives the live surface the color transition in effect now
    /// (``ColorTransition/current``), so the config call that follows blends the terminal's
    /// palette and default colors on the GPU from the colors on screen, with the window's curve
    /// (`ghostty_surface_set_color_transition`). Call it before every config call that can change
    /// colors; `animated` false makes that change instant (a surface that shows nothing yet).
    func applyColorTransition(animated: Bool = true) {
        guard let surface else { return }
        guard animated else {
            // SAFETY: the view's live surface (TerminalSurfaceView.surface); nil clears the transition.
            unsafe ghostty_surface_set_color_transition(surface, nil)
            return
        }
        let transition = ColorTransition.current
        var spec = ghostty_color_transition_s()
        spec.duration = transition.seconds
        spec.space = transition.mixesInSRGB ? GHOSTTY_COLOR_TRANSITION_SRGB : GHOSTTY_COLOR_TRANSITION_OKLAB
        let samples = transition.isInstant ? [] : transition.keyframeProgress
        let count = min(samples.count, Int(GHOSTTY_COLOR_TRANSITION_MAX_SAMPLES))
        spec.sample_count = UInt32(count)
        // SAFETY: `samples` is a C array of GHOSTTY_COLOR_TRANSITION_MAX_SAMPLES floats, so its
        // bytes bind to Float, and `count` is at most that many (clamped above).
        unsafe withUnsafeMutableBytes(of: &spec.samples) { raw in
            // SAFETY: as above.
            let floats = unsafe raw.bindMemory(to: Float.self)
            // SAFETY: as above.
            for index in 0..<count { unsafe floats[index] = Float(samples[index]) }
        }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface); Ghostty copies `spec`,
        // which lives for the call.
        unsafe ghostty_surface_set_color_transition(surface, &spec)
    }
}
