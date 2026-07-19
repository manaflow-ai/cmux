#if DEBUG
/// Credential-free proof produced by one real mobile-shell Iroh transaction.
public struct MobileIrohReleaseGateProbeResult: Equatable, Sendable {
    /// Whether `mobile.host.status` decoded over the authenticated session.
    public let hostStatusVerified: Bool
    /// Whether a unique terminal marker traveled phone to Mac and back.
    public let terminalRoundTripVerified: Bool
    /// Whether a workspace was renamed and restored through RPC.
    public let workspaceMutationVerified: Bool

    /// Creates a successful probe result.
    /// - Parameters:
    ///   - hostStatusVerified: Host-status verification result.
    ///   - terminalRoundTripVerified: Terminal round-trip verification result.
    ///   - workspaceMutationVerified: Reversible workspace mutation result.
    public init(
        hostStatusVerified: Bool,
        terminalRoundTripVerified: Bool,
        workspaceMutationVerified: Bool
    ) {
        self.hostStatusVerified = hostStatusVerified
        self.terminalRoundTripVerified = terminalRoundTripVerified
        self.workspaceMutationVerified = workspaceMutationVerified
    }
}
#endif
