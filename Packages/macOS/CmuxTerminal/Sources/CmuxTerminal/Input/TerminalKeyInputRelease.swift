/// Metadata paired with one physical key release.
public struct TerminalKeyInputRelease: Sendable, Equatable {
    /// Whether libghostty owns the paired physical release.
    public let forwardsPhysicalKey: Bool

    /// The physical-layout identity captured on the initial terminal press.
    public let unshiftedCodepoint: UInt32?
}
