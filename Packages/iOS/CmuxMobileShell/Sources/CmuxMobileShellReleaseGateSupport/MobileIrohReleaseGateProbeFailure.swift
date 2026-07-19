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
}
#endif
