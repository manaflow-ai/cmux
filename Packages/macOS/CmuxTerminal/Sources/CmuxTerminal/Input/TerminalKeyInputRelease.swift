/// Metadata paired with one physical key release.
public struct TerminalKeyInputRelease: Sendable, Equatable {
    /// Whether libghostty owns the paired physical release.
    public let forwardsPhysicalKey: Bool

    /// Binding metadata captured when the terminal-owned lifecycle began.
    public let physicalIdentity: TerminalKeyInputPhysicalIdentity?

    /// Physical-layout codepoint paired with Ghostty's consumed press.
    public var unshiftedCodepoint: UInt32? {
        physicalIdentity?.unshiftedCodepoint
    }
}
