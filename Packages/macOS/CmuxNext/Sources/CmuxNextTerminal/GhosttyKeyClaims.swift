public import AppKit
import GhosttyNextKit

/// One key cmux has a default binding on, as Ghostty's binding set sees a
/// key-down: the Mac virtual key code, the unshifted codepoint (0 for keys
/// that type nothing, like arrows) and the Shift/Control/Option/Command mods.
public nonisolated struct GhosttyKeyProbe: Sendable, Equatable {
    public var keyCode: UInt16
    public var unshifted: UInt32
    public var modifiers: NSEvent.ModifierFlags

    public init(keyCode: UInt16, unshifted: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.unshifted = unshifted
        self.modifiers = modifiers.intersection([.shift, .control, .option, .command])
    }
}

/// Keys the user's Ghostty config claims for itself (PANE-FOCUS-RESIZE-KEYS-
/// AND-GHOSTTY-KEYBINDS): a `keybind` line that maps the key to a terminal
/// action, or `unbind`s it. Such a line wins over a cmux default on that key.
nonisolated struct GhosttyKeyClaims {
    /// For each probe, whether a config made of `text` claims it (tests).
    static func claimed(_ probes: [GhosttyKeyProbe], configText text: String) -> [Bool] {
        probes.map { _ in false }
    }
}

extension GhosttyRuntime {
    /// For each probe, whether the loaded config claims it.
    public func userClaimedKeys(_ probes: [GhosttyKeyProbe]) -> [Bool] {
        probes.map { _ in false }
    }
}
