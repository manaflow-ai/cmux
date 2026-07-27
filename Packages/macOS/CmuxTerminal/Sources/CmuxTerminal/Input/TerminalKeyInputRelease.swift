/// Metadata paired with one physical key release.
public struct TerminalKeyInputRelease: Sendable, Equatable {
    /// Whether libghostty owns the paired physical release.
    public let forwardsPhysicalKey: Bool

    /// Translation metadata captured on the initial terminal press.
    public let physicalIdentity: TerminalKeyInputPhysicalIdentity?

    /// Physical-layout codepoint captured on the initial terminal press.
    public var unshiftedCodepoint: UInt32? {
        physicalIdentity?.unshiftedCodepoint
    }

    /// Raw modifier mask consumed to produce the initial translated text.
    public var consumedModifierMask: UInt32? {
        physicalIdentity?.consumedModifierMask
    }
}
