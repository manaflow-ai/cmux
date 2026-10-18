public import CmuxNextDesign

/// cmux's own window background (`appearance.backgroundOpacity`,
/// `appearance.backgroundBlur` in cmux.json), loaded after the Ghostty
/// config files like `fontOverride`, so the opacity the surfaces, the
/// window and the theme read is the resolved one. Set, then call
/// `reloadConfig()`.
extension GhosttyRuntime {
    /// cmux.json's window background, laid over the config files' opacity
    /// and blur on every config load. Empty (the default) keeps them.
    public static var backgroundOverride = WindowBackgroundOverride()

    /// Whether cmux.json overrides the terminal's background
    /// (`appearance.surfaces.terminal`): the surfaces then draw a
    /// transparent default background in every window and the terminal
    /// host paints the override (`GhosttyRuntimeSurfacePolicy`). Set, then
    /// call `reloadConfig()`.
    public static var terminalBackgroundOverridden = false

    /// Whether `appearance.background` shows art. Over art a window is
    /// see-through at any opacity (`WindowBackdrop`), so the surfaces draw a
    /// transparent default background and the terminal host paints what the
    /// panes paint there (`GhosttyRuntimeSurfacePolicy`). Set, then call
    /// `reloadConfig()`.
    public static var appBackdropArtShown = false

    /// Whether some workspace shows its own art (cx-t2x.5), like
    /// `appBackdropArtShown`. Set, then call `reloadConfig()`.
    public static var workspaceBackdropArtShown = false

    /// Whether any window may show art behind its terminals.
    static var backdropArtShown: Bool { appBackdropArtShown || workspaceBackdropArtShown }

    /// Config lines that turn the config's `background-opacity` and
    /// `background-blur` into what `background` resolves them to; empty
    /// when nothing changes.
    ///
    /// - Parameter background: The cmux.json override.
    /// - Parameter configuredOpacity: The config's `background-opacity`.
    /// - Parameter configuredBlur: The config's `background-blur`, in
    ///   Ghostty's C encoding.
    /// - Returns: Lines for `ghostty_config_load_string`.
    public nonisolated static func backgroundOverrideLines(_ background: WindowBackgroundOverride,
                                                           configuredOpacity: Double, configuredBlur: Int) -> [String] {
        let resolved = background.resolved(backgroundOpacity: configuredOpacity, backgroundBlur: configuredBlur)
        var lines: [String] = []
        if resolved.backgroundOpacity != configuredOpacity {
            lines.append("background-opacity = \(resolved.backgroundOpacity)")
        }
        if resolved.backgroundBlur != configuredBlur {
            switch resolved.backgroundBlur {
            case -1: lines.append("background-blur = macos-glass-regular")
            case -2: lines.append("background-blur = macos-glass-clear")
            case let radius: lines.append("background-blur = \(max(radius, 0))")
            }
        }
        return lines
    }
}
