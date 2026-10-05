import AppKit
import CmuxNextActions
import CmuxNextTerminal

extension KeyRouter {
    /// Loads the user's Ghostty keybinds (`binds`, the loaded config) and
    /// Ghostty's own defaults (`defaults`, a config with no user files).
    func loadGhosttyKeybinds(_ binds: [GhosttyHostKeybind], defaults: [GhosttyHostKeybind]) {
        ghosttyHostAction = { event in binds.first { $0.matches(event) }?.action }
    }
}
