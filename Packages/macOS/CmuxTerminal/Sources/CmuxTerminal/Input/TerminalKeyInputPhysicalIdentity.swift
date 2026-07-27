/// Ghostty binding identity for one physical key press lifecycle.
///
/// The tracker already keys lifecycles by native keycode. This stores the
/// layout-dependent component of Ghostty's consumed-binding release hash.
/// Repeat text and consumed modifiers remain event-local and are not identity.
public struct TerminalKeyInputPhysicalIdentity: Sendable, Equatable {
    /// Physical-layout codepoint captured when the lifecycle begins.
    public let unshiftedCodepoint: UInt32

    /// Creates a binding identity for one held physical key.
    public init(unshiftedCodepoint: UInt32) {
        self.unshiftedCodepoint = unshiftedCodepoint
    }
}
