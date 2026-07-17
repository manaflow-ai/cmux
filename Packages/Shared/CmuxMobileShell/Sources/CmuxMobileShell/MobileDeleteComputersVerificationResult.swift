#if DEBUG
/// Full result emitted by the delete-computers simulator verifier.
public struct MobileDeleteComputersVerificationResult: Codable, Equatable, Sendable {
    /// Whether every verifier assertion passed.
    public var passed: Bool
    /// Compact pass/fail reason shown in the verifier UI.
    public var reason: String
    /// Mac ids removed during the half-delete phase.
    public var deletedHalfMacIDs: [String]
    /// Mac ids removed across the whole verifier run.
    public var deletedAllMacIDs: [String]
    /// Whether workspaces from the half-deleted Macs disappeared.
    public var halfRemovedAbsent: Bool
    /// Whether workspaces from the remaining Macs stayed visible.
    public var halfRemainingPresent: Bool
    /// Whether the workspace list stayed out of the disconnected-banner state.
    public var halfNoDisconnectedBanner: Bool
    /// Whether pull-to-refresh preserved the half-deleted workspace list.
    public var refreshPreservedHalfList: Bool
    /// Whether deleting all Macs removed every workspace and computer row.
    public var allRemoved: Bool
    /// Whether pull-to-refresh preserved the empty post-delete list.
    public var refreshPreservedEmptyList: Bool
    /// Ordered checkpoints captured during the verifier run.
    public var checkpoints: [MobileDeleteComputersVerificationCheckpoint]
    /// Path to the JSON evidence file written by the verifier, when available.
    public var evidencePath: String?
}
#endif
