import GhosttyNextKit

/// The Ghostty config's `unfocused-split-opacity` and `unfocused-split-fill`.
/// The App turns this into CmuxNextDesign's `UnfocusedPaneDim`.
public nonisolated struct GhosttyUnfocusedSplit: Hashable, Sendable {
    /// `unfocused-split-opacity`, 0.15...1 after Ghostty's clamp; 1 is no dim.
    public var opacity: Double
    /// `unfocused-split-fill`; nil is the theme background.
    public var fill: GhosttyThemeColors.RGB?

    public init(opacity: Double = 1, fill: GhosttyThemeColors.RGB? = nil) {
        self.opacity = opacity
        self.fill = fill
    }

    /// The keys of `config`, a live handle the caller holds for the call.
    init(config: ghostty_config_t) {
        var opacity: Double = 1
        // SAFETY: the caller's live config; unfocused-split-opacity is a C double.
        _ = unsafe GhosttyRuntime.configGet(config, &opacity, key: "unfocused-split-opacity")
        var color = ghostty_config_color_s()
        // SAFETY: the caller's live config; unfocused-split-fill is a color.
        let fill = unsafe GhosttyRuntime.configGet(config, &color, key: "unfocused-split-fill")
            ? GhosttyThemeColors.RGB(r: color.r, g: color.g, b: color.b) : nil
        self.init(opacity: opacity, fill: fill)
    }

    /// cmux's `unfocused-split-opacity`, loaded before the user's files: no
    /// dim unless they set one (Ghostty's own default is 0.7).
    static let defaultLine = "unfocused-split-opacity = 1"

    static func loadDefault(into config: ghostty_config_t) {
        // SAFETY: the caller passes a live config.
        unsafe GhosttyRuntime.loadConfigLine(defaultLine, into: config, source: "cmux-next")
    }

    /// The keys a user config made of `text` (Ghostty config lines)
    /// resolves to, loaded the way `loadConfig` loads them, for tests.
    @MainActor static func resolved(configText text: String) -> GhosttyUnfocusedSplit? {
        _ = GhosttyRuntime.shared // runs ghostty_init, which config_new needs
        // SAFETY: withScratchConfig's handle is live for each closure's call and stays in it.
        return unsafe GhosttyRuntime.withScratchConfig(load: {
            // SAFETY: as above.
            unsafe loadDefault(into: $0)
            // SAFETY: as above.
            unsafe GhosttyRuntime.loadConfigLine(text, into: $0, source: "test")
        }, read: {
            // SAFETY: as above.
            unsafe GhosttyUnfocusedSplit(config: $0)
        })
    }
}

extension GhosttyRuntime {
    /// The unfocused-split keys of the applied config; no dim when none loaded.
    public var unfocusedSplit: GhosttyUnfocusedSplit {
        guard let config else { return GhosttyUnfocusedSplit() }
        // SAFETY: `config` is the live applied config (GhosttyRuntime's note), held for this call.
        return unsafe GhosttyUnfocusedSplit(config: config)
    }
}
