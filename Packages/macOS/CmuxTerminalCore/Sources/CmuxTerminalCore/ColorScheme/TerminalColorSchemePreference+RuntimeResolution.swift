/// Runtime color-scheme decisions the terminal makes while loading Ghostty
/// config, lifted from `GhosttyApp`/`GhosttyNSView` as pure value computations.
///
/// The app side keeps the live inputs: it reads the perceived background color
/// (resolving it to a readable light/dark scheme) and classifies the reload
/// source, then passes the resolved booleans in here so the decision stays a
/// deterministic transform on ``TerminalColorSchemePreference``.
extension TerminalColorSchemePreference {
    /// The runtime preference implied by a surface's readable background scheme:
    /// a readable-light background prefers `.light`, otherwise `.dark`.
    public static func runtimePreference(readableSchemeIsLight: Bool) -> TerminalColorSchemePreference {
        readableSchemeIsLight ? .light : .dark
    }

    /// The color scheme to load config with, holding the resolved terminal scheme
    /// stable for cmux single-theme reloads.
    ///
    /// For a cmux theme-reload source whose theme value resolves to the same
    /// theme in both color schemes, the effective terminal scheme is kept so a
    /// same-scheme theme change does not flash through app mode; otherwise the
    /// requested scheme is used directly.
    public static func runtimeColorSchemeForConfigLoad(
        isCmuxThemeReloadSource: Bool,
        requestedColorScheme: TerminalColorSchemePreference,
        effectiveTerminalColorScheme: TerminalColorSchemePreference,
        cmuxThemeValue: String?
    ) -> TerminalColorSchemePreference {
        guard isCmuxThemeReloadSource,
              let cmuxThemeValue,
              GhosttyConfig.themeValueUsesSameResolvedThemeInBothColorSchemes(cmuxThemeValue) else {
            return requestedColorScheme
        }

        return effectiveTerminalColorScheme
    }
}
