import GhosttyKit

/// cmux's Ghostty keybind defaults, loaded before the user's files. Stub:
/// none yet.
extension GhosttyRuntime {
    nonisolated static let cmuxDefaultKeybindLines: [String] = []

    /// Loads the defaults into `config`; call before the user's files.
    static func loadKeybindDefaults(into config: ghostty_config_t) {
        for line in cmuxDefaultKeybindLines {
            line.withCString { ghostty_config_load_string(config, $0, UInt(line.utf8.count), "cmux-next") }
        }
    }

    /// Whether Ghostty `action` has a keybind in a user config made of
    /// `text` (Ghostty config lines), loaded the way `loadConfig` loads it,
    /// for tests.
    static func isBound(_ action: String, configText text: String) -> Bool {
        guard let config = ghostty_config_new() else { return false }
        defer { ghostty_config_free(config) }
        loadKeybindDefaults(into: config)
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "test") }
        ghostty_config_finalize(config)
        let trigger = action.withCString { ghostty_config_trigger(config, $0, UInt(action.utf8.count)) }
        switch trigger.tag {
        case GHOSTTY_TRIGGER_UNICODE: return trigger.key.unicode != 0
        case GHOSTTY_TRIGGER_PHYSICAL: return trigger.key.physical != GHOSTTY_KEY_UNIDENTIFIED
        default: return false
        }
    }
}
