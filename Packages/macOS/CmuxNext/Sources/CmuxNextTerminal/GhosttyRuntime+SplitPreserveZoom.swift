import GhosttyNextKit

/// Ghostty's `split-preserve-zoom` (cmux#47785): which split actions keep a zoomed split zoomed.
/// `navigation` makes a pane-navigation key (Ghostty's `goto_split`; cmux's Focus Pane Left/Right/Up/Down,
/// Next and Previous Pane) move the zoom to the pane it lands on instead of leaving the zoom where it was.
/// Ghostty's default is none.
public nonisolated struct GhosttySplitPreserveZoom: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    /// `split-preserve-zoom = navigation`.
    public static let navigation = GhosttySplitPreserveZoom(rawValue: 1 << 0)

    init(config: ghostty_config_t) {
        // A packed struct of bools: Ghostty.app reads it as one `c_uint` of flags.
        var bits: UInt32 = 0
        let key = "split-preserve-zoom"
        let found = withUnsafeMutablePointer(to: &bits) { pointer in
            key.withCString { ghostty_config_get(config, pointer, $0, UInt(key.utf8.count)) }
        }
        self.init(rawValue: found ? bits : 0)
    }

    /// The flags of a config made of `text` (Ghostty config lines), for tests.
    init(configText text: String) {
        guard let config = ghostty_config_new() else { self.init(); return }
        defer { ghostty_config_free(config) }
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "test") }
        ghostty_config_finalize(config)
        self.init(config: config)
    }
}

extension GhosttyRuntime {
    /// `split-preserve-zoom` of the applied config; Ghostty's default (none) when none loaded.
    public var splitPreserveZoom: GhosttySplitPreserveZoom {
        guard let config else { return GhosttySplitPreserveZoom() }
        return GhosttySplitPreserveZoom(config: config)
    }
}
