/// Translation metadata for one physical key event and its press lifecycle.
///
/// The initial press identity is retained for release matching. Each repeat
/// resolves its own identity so modifier, layout, and input-method changes can
/// update its semantic text without changing the lifecycle owner.
public struct TerminalKeyInputPhysicalIdentity: Sendable, Equatable {
    /// Physical-layout codepoint resolved for this key event.
    public let unshiftedCodepoint: UInt32

    /// Platform-neutral raw modifier mask consumed to produce this event's text.
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
