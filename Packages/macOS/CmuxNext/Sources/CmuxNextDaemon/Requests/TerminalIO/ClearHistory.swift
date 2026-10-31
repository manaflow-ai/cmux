import Foundation

/// `clear-history`: Cmd-K (Clear Screen and Scrollback) in the daemon, which owns the terminal
/// state. The daemon erases the primary screen's rows before the shell prompt and the retained
/// history, and every attached view gets the same erase; an alternate-screen program is left
/// untouched, or gets `fallbackKey` encoded with the terminal's own keyboard modes (Claude Code
/// reads Cmd-K as Clear Screen, as Ghostty's `performable:clear_screen` passes it on). It fails
/// without a change when it cannot restore the cursor exactly, and with
/// ``fallbackUnrepresentable`` when the program's keyboard mode has no encoding for the key.
public struct ClearHistoryRequest: DaemonRequest {
    public struct Response: Decodable, Sendable {}
    public static let command = "clear-history"
    public var surface: SurfaceID
    public var fallbackKey: DaemonKeyInput?

    /// The daemon's answer when an alternate-screen program's keyboard mode cannot encode
    /// `fallbackKey` (legacy encoding sends nothing for a Command key): nothing changed.
    public static let fallbackUnrepresentable = "cannot encode clear-history fallback key"

    public init(surface: SurfaceID, fallbackKey: DaemonKeyInput? = nil) {
        self.surface = surface
        self.fallbackKey = fallbackKey
    }
}

/// One key press the daemon encodes with the terminal's own keyboard modes (Kitty flags,
/// modifyOtherKeys): `ProtocolKeyInput` in cmux-tui-core `server/protocol_key.rs`.
public struct DaemonKeyInput: Encodable, Sendable, Equatable {
    public struct Modifiers: Encodable, Sendable, Equatable {
        public var shift = false
        public var control = false
        public var alt = false
        public var `super` = false
        public var capsLock = false
        public var numLock = false
    }

    /// Ghostty's kebab-case key name (`k`, `digit-1`, `arrow-left`).
    public var key: String
    public var mods: Modifiers
    public var consumedMods = Modifiers()
    public var utf8 = ""
    public var unshiftedCodepoint: String?
    public var action = "press"
    public var macosOptionAsAlt = true

    /// Command plus a lowercase ASCII letter (Cmd-K).
    public static func command(_ letter: Character) -> DaemonKeyInput {
        DaemonKeyInput(key: String(letter), mods: Modifiers(super: true), unshiftedCodepoint: String(letter))
    }
}
