import GhosttyNextKit

/// cmux's Ghostty keybind defaults, loaded before the user's files, so a
/// later `keybind` line of theirs for the same trigger replaces the unbind
/// inside Ghostty's config. Ghostty's macOS default
/// `super+j=scroll_to_selection` is unbound: Cmd-J is cmux's leader key
/// (`LeaderLayer` in CmuxNextActions), and Scroll to Selection moved to
/// Cmd-J J (`terminal.scrollToSelection`). The key router arms the leader
/// before a terminal sees the key, so a user's Ghostty `super+j` keybind
/// runs only once the leader chords are unbound in cmux.json.
///
/// Like the shipping cmux (plans/cmux-next/terminal-shortcuts.md), these
/// Ghostty window defaults are unbound so the keys reach the terminal
/// program: `super+enter=toggle_fullscreen` (cmux's full screen is
/// Ctrl-Cmd-F), `super+alt+w=close_tab:this` (Cmd-W closes a tab) and
/// `super+alt+shift+w=close_all_windows`.
extension GhosttyRuntime {
    nonisolated static let cmuxDefaultKeybindLines = [
        "keybind = super+j=unbind",
        "keybind = super+enter=unbind",
        "keybind = super+alt+w=unbind",
        "keybind = super+alt+shift+w=unbind",
    ]

    /// Loads the defaults into `config`; call before the user's files.
    nonisolated static func loadKeybindDefaults(into config: ghostty_config_t) {
        for line in cmuxDefaultKeybindLines {
            // SAFETY: the caller passes a live config.
            unsafe loadConfigLine(line, into: config, source: "cmux-next")
        }
    }

    /// Whether Ghostty `action` has a keybind in a user config made of
    /// `text` (Ghostty config lines), loaded the way `loadConfig` loads it,
    /// for tests.
    static func isBound(_ action: String, configText text: String) -> Bool {
        // SAFETY: withScratchConfig's handle is live for each closure's call and stays in it.
        let read = unsafe withScratchConfig(load: {
            // SAFETY: as above.
            unsafe loadKeybindDefaults(into: $0)
            // SAFETY: as above.
            unsafe loadConfigLine(text, into: $0, source: "test")
        }, read: { config in
            // SAFETY: as above; Swift passes a NUL-terminated copy of `action` for the call.
            unsafe ghostty_config_trigger(config, action, UInt(action.utf8.count))
        })
        guard let trigger = read else { return false }
        switch trigger.tag {
        case GHOSTTY_TRIGGER_UNICODE: return trigger.key.unicode != 0
        case GHOSTTY_TRIGGER_PHYSICAL: return trigger.key.physical != GHOSTTY_KEY_UNIDENTIFIED
        default: return false
        }
    }
}
