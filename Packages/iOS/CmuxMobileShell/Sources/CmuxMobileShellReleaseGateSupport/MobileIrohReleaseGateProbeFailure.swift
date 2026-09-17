#if DEBUG
/// A bounded failure from the simulator-only Iroh release-gate probe.
///
/// Cases intentionally omit identifiers, terminal contents, workspace names,
/// and transport addresses so a serialized gate result cannot disclose user
/// data or network topology.
public enum MobileIrohReleaseGateProbeFailure: String, Error, Equatable, Sendable {
    /// The shell did not hold a live authenticated Iroh session.
    case unauthenticatedIrohSession
    /// The authenticated host-status RPC did not return current-main identity.
    case hostStatusRejected
    /// No selected terminal could be exercised.
    case terminalUnavailable
    /// The terminal input marker did not return through the output stream.
    case terminalRoundTripFailed
    /// No workspace supporting a reversible rename was available.
    case workspaceMutationUnavailable
    /// The temporary workspace rename failed or was not reflected by refresh.
    case workspaceMutationFailed
    /// The probe could not restore the workspace's original name.
    case workspaceRestorationFailed
    /// The independent server-event lane could not be subscribed and removed.
    case independentEventsFailed
    /// The content-free notification reconciliation RPC failed validation.
    case notificationReconcileFailed
    /// The workspace-scoped chat-session snapshot failed validation.
    case chatSessionsFailed
    /// The terminal artifact count-only scan failed validation.
    case artifactScanCountFailed
    /// Required local endpoint or QUIC continuity evidence was unavailable.
    case continuityEvidenceUnavailable
    /// The endpoint, native connection, or credential expiry violated rollover.
    case relayRolloverFailed
    /// The RPC control stream or held terminal stream did not survive rollover.
    case controlStreamContinuityFailed
    /// The installed independent event registration did not survive rollover.
    case independentEventsContinuityFailed
    /// The terminal never confirmed that the rollover artifact was closed.
    case artifactCommandNotCompleted
    /// The artifact scan never authorized the exact generated path.
    case artifactScanPathMissing
    /// The artifact did not reach two stable observations at the expected size.
    case artifactStatSizeMismatch
    /// Artifact scan or stat RPC transport failed before readiness was established.
    case artifactReadinessRPCFailed
    /// The Mac returned no valid artifact-lane descriptor for the completed file.
    case artifactDescriptorInvalid
    /// The artifact descriptor RPC failed before returning a response.
    case artifactDescriptorRPCFailed
    /// The independent Iroh artifact stream could not be opened.
    case artifactLaneOpenFailed
    /// The independent Iroh artifact stream returned a transport read error.
    case artifactLaneReadFailed
    /// The independent artifact stream did not begin with the expected byte.
    case artifactLaneInitialByteMismatch
    /// The independent artifact stream returned more bytes than the descriptor promised.
    case artifactLaneOverrun
    /// The independent artifact stream ended before the descriptor's promised size.
    case artifactLaneTruncated
    /// The independent artifact stream ended with unexpected content.
    case artifactLaneTailMismatch
    /// A held relay credential remained admitted beyond its hard expiry.
    case unrefreshedCredentialDidNotDisconnect
}
#endif
