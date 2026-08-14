import Foundation

/// One keystroke in a (possibly chorded) shortcut.
///
/// `key` is the platform-canonical lower-case character or named token
/// (e.g. `"a"`, `"space"`, `"return"`, `"f5"`, `"←"`). `keyCode` is the
/// optional macOS virtual key code, captured when the user records a
/// shortcut so we can re-match the same physical key after a layout
/// change. Modifier flags are flat booleans because the cmux JSON
/// config encodes them that way for easy hand-editing.
public struct ShortcutStroke: Sendable, Equatable, Hashable, Codable {
    public let key: String
    public let command: Bool
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let keyCode: UInt16?

    public init(
        key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false,
        keyCode: UInt16? = nil
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.keyCode = keyCode
    }

    /// True when at least one of `cmd`, `shift`, `opt`, or `ctrl` is set.
    public var hasAnyModifier: Bool { command || shift || option || control }

    /// Returns this stroke with its key normalized to cmux's persisted
    /// physical-key representation when a recording-time key code is present.
    public func canonicalized() -> ShortcutStroke {
        ShortcutStroke(
            key: canonicalShortcutKey(key, keyCode: keyCode),
            command: command,
            shift: shift,
            option: option,
            control: control,
            keyCode: keyCode
        )
    }

    /// Returns whether two strokes represent the same key event for routing.
    ///
    /// The recording-time virtual key code is persistence metadata, not part
    /// of a chord's logical identity. A binding loaded from hand-written JSON
    /// may omit it while the shared prefix (or a Settings recording) retains
    /// one. Comparing the full ``Equatable`` value in that case would let the
    /// router arm successfully and then make the action dispatcher reject the
    /// otherwise valid suffix. Canonical keys and modifier flags are the
    /// complete routing identity; ``keyCode`` is intentionally ignored.
    public func isRoutingEquivalent(to other: ShortcutStroke) -> Bool {
        let lhs = canonicalized()
        let rhs = other.canonicalized()
        return lhs.key.lowercased() == rhs.key.lowercased()
            && lhs.command == rhs.command
            && lhs.shift == rhs.shift
            && lhs.option == rhs.option
            && lhs.control == rhs.control
    }
}
