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

    /// True when a primary modifier (`cmd`, `opt`, or `ctrl`) is set.
    ///
    /// Shift alone does not count: a system-wide Carbon hotkey requires one
    /// of these primary modifiers to register. Mirrors the app target's
    /// `StoredShortcut.hasPrimaryModifier`, which the runtime's
    /// `normalizedSystemWideHotkeyShortcutResult` gate uses.
    public var hasPrimaryModifier: Bool { command || option || control }
}
