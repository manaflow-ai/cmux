/// A layout-resolved physical key event encoded by the backend's canonical VT state.
public struct BackendTerminalKeyEvent: Equatable, Sendable {
    /// Ghostty's stable W3C physical-key value.
    public let key: UInt32

    /// Ghostty modifier bits active for this event.
    public let modifiers: UInt16

    /// Active modifiers consumed while producing ``text``.
    public let consumedModifiers: UInt16

    /// Layout-resolved printable text, excluding C0 and DEL controls.
    public let text: String

    /// Layout codepoint before Shift was applied, or zero when unknown.
    public let unshiftedCodepoint: UInt32

    /// Press, release, or repeat semantics.
    public let action: BackendTerminalKeyAction

    /// Creates one semantic key event.
    public init(
        key: UInt32,
        modifiers: UInt16 = 0,
        consumedModifiers: UInt16 = 0,
        text: String = "",
        unshiftedCodepoint: UInt32 = 0,
        action: BackendTerminalKeyAction = .press
    ) {
        self.key = key
        self.modifiers = modifiers
        self.consumedModifiers = consumedModifiers
        self.text = text
        self.unshiftedCodepoint = unshiftedCodepoint
        self.action = action
    }
}
