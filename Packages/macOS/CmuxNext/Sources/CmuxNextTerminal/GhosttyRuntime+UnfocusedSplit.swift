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

    init(config: ghostty_config_t) {
        var opacity: Double = 1
        _ = Self.get(config, &opacity, key: "unfocused-split-opacity")
        var color = ghostty_config_color_s()
        let fill = Self.get(config, &color, key: "unfocused-split-fill")
            ? GhosttyThemeColors.RGB(r: color.r, g: color.g, b: color.b) : nil
        self.init(opacity: opacity, fill: fill)
    }

    /// `ghostty_config_get` for one key, callable off the main actor.
    private static func get<T: BitwiseCopyable>(_ config: ghostty_config_t, _ value: inout T, key: String) -> Bool {
        withUnsafeMutablePointer(to: &value) { pointer in
            key.withCString { ghostty_config_get(config, pointer, $0, UInt(key.utf8.count)) }
        }
    }

    /// cmux's `unfocused-split-opacity`, loaded before the user's files: no
    /// dim unless they set one (Ghostty's own default is 0.7).
    static let defaultLine = "unfocused-split-opacity = 1"

    static func loadDefault(into config: ghostty_config_t) {
        let line = defaultLine
        line.withCString { ghostty_config_load_string(config, $0, UInt(line.utf8.count), "cmux-next") }
    }

    /// The keys a user config made of `text` (Ghostty config lines)
    /// resolves to, loaded the way `loadConfig` loads them, for tests.
    @MainActor static func resolved(configText text: String) -> GhosttyUnfocusedSplit? {
        _ = GhosttyRuntime.shared // runs ghostty_init, which config_new needs
        guard let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }
        loadDefault(into: config)
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "test") }
        ghostty_config_finalize(config)
        return GhosttyUnfocusedSplit(config: config)
    }
}

extension GhosttyRuntime {
    /// The unfocused-split keys of the applied config; no dim when none loaded.
    public var unfocusedSplit: GhosttyUnfocusedSplit { config.map(GhosttyUnfocusedSplit.init(config:)) ?? GhosttyUnfocusedSplit() }
}
