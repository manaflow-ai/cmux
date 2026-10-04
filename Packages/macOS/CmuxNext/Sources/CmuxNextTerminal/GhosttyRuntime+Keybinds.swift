import GhosttyNextKit

/// cmux's Ghostty keybind defaults, loaded before the user's files, so a
/// later `keybind` line of theirs for the same trigger replaces the unbind
/// inside Ghostty's config. Ghostty's macOS default
/// `super+j=scroll_to_selection` is unbound: Cmd-J is cmux's leader key
/// (`LeaderLayer` in CmuxNextActions), and Scroll to Selection moved to
/// Cmd-J J (`terminal.scrollToSelection`). The key router arms the leader
/// before a terminal sees the key, so a user's Ghostty `super+j` keybind
/// runs only once the leader chords are unbound in cmux.json.
extension GhosttyRuntime {
    nonisolated static let cmuxDefaultKeybindLines = ["keybind = super+j=unbind"]

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
