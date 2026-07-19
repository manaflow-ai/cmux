#if DEBUG
/// Credential-free proof produced by one real mobile-shell Iroh transaction.
public struct MobileIrohReleaseGateProbeResult: Equatable, Sendable {
    /// Whether `mobile.host.status` decoded over the authenticated session.
    public let hostStatusVerified: Bool
    /// Whether a unique terminal marker traveled phone to Mac and back.
    public let terminalRoundTripVerified: Bool
    /// Whether a workspace was renamed and restored through RPC.
    public let workspaceMutationVerified: Bool
    /// Whether a dedicated independent-event registration was installed and removed.
    public let independentEventsVerified: Bool
    /// Whether a read-only notification reconciliation response decoded.
    public let notificationReconcileVerified: Bool
    /// Whether the selected workspace's chat-session snapshot decoded.
    public let chatSessionsVerified: Bool
    /// Whether a content-free terminal artifact count scan decoded.
    public let artifactScanCountVerified: Bool

    /// Creates a successful probe result.
    /// - Parameters:
    ///   - hostStatusVerified: Host-status verification result.
    ///   - terminalRoundTripVerified: Terminal round-trip verification result.
    ///   - workspaceMutationVerified: Reversible workspace mutation result.
    ///   - independentEventsVerified: Independent event lane verification result.
    ///   - notificationReconcileVerified: Notification reconcile verification result.
    ///   - chatSessionsVerified: Chat-session snapshot verification result.
    ///   - artifactScanCountVerified: Artifact count-only scan verification result.
    public init(
        hostStatusVerified: Bool,
        terminalRoundTripVerified: Bool,
        workspaceMutationVerified: Bool,
        independentEventsVerified: Bool,
        notificationReconcileVerified: Bool,
        chatSessionsVerified: Bool,
        artifactScanCountVerified: Bool
    ) {
        self.hostStatusVerified = hostStatusVerified
        self.terminalRoundTripVerified = terminalRoundTripVerified
        self.workspaceMutationVerified = workspaceMutationVerified
        self.independentEventsVerified = independentEventsVerified
        self.notificationReconcileVerified = notificationReconcileVerified
        self.chatSessionsVerified = chatSessionsVerified
        self.artifactScanCountVerified = artifactScanCountVerified
    }
}
#endif
