/// Translation metadata fixed for one physical key press lifecycle.
///
/// Text, its consumed modifiers, and its physical-layout codepoint describe one
/// semantic key action. Repeats and release must retain this identity even when
/// the active keyboard layout or input method changes while the key is held.
public struct TerminalKeyInputPhysicalIdentity: Sendable, Equatable {
    /// Physical-layout codepoint captured from the initial terminal action.
    public let unshiftedCodepoint: UInt32

    /// Platform-neutral raw modifier mask consumed to produce the initial text.
    public let consumedModifierMask: UInt32

    /// Creates a complete physical key identity.
    public init(
        unshiftedCodepoint: UInt32,
        consumedModifierMask: UInt32
    ) {
        self.unshiftedCodepoint = unshiftedCodepoint
        self.consumedModifierMask = consumedModifierMask
    }
}
