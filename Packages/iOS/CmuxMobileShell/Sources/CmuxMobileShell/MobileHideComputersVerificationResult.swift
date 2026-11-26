#if DEBUG
/// Full result emitted by the hide-computers simulator verifier.
public struct MobileHideComputersVerificationResult: Codable, Equatable, Sendable {
    /// Whether every verifier assertion passed.
    public var passed: Bool
    /// Compact pass/fail reason shown in the verifier UI.
    public var reason: String
    /// Mac ids hidden during the first phase.
    public var hiddenHalfMacIDs: [String]
    /// Mac ids hidden across the whole verifier run.
    public var hiddenAllMacIDs: [String]
    /// Whether workspaces from the half-hidden Macs disappeared.
    public var halfHiddenAbsent: Bool
    /// Whether workspaces from the remaining Macs stayed visible.
    public var halfRemainingPresent: Bool
    /// Whether the workspace list stayed out of the disconnected-banner state.
    public var halfNoDisconnectedBanner: Bool
    /// Whether pull-to-refresh preserved the half-hidden workspace list.
    public var refreshPreservedHalfList: Bool
    /// Whether hiding all Macs removed every workspace and computer row.
    public var allHidden: Bool
    /// Whether the saved-Mac hint remained set after every visible Mac was hidden.
    public var allHiddenKnownPairedMac: Bool
    /// Whether the all-hidden workspace list presented as a healthy normal-empty list.
    public var allHiddenNormalEmpty: Bool
    /// Whether pull-to-refresh preserved the empty post-hide list.
    public var refreshPreservedEmptyList: Bool
    /// Ordered checkpoints captured during the verifier run.
    public var checkpoints: [MobileHideComputersVerificationCheckpoint]
    /// Path to the JSON evidence file written by the verifier, when available.
    public var evidencePath: String?
}
#endif
