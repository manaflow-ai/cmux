import Foundation

// ClearHistoryRequest is generated (bindings.json, family TerminalIO).
extension ClearHistoryRequest {
    /// The daemon's answer when an alternate-screen program's keyboard mode cannot encode
    /// `fallbackKey` (legacy encoding sends nothing for a Command key): nothing changed.
    public static let fallbackUnrepresentable = "cannot encode clear-history fallback key"
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
