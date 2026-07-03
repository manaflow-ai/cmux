#if DEBUG
/// Snapshot of the verifier state after one delete or refresh step.
public struct MobileDeleteComputersVerificationCheckpoint: Codable, Equatable, Sendable {
    /// Human-readable checkpoint name.
    public var name: String
    /// Number of visible workspace rows.
    public var workspaceCount: Int
    /// Workspace identifiers visible at this checkpoint.
    public var workspaceIDs: [String]
    /// Distinct Mac ids represented by visible workspace rows.
    public var workspaceMacIDs: [String]
    /// Mac ids visible in the Computers list.
    public var displayMacIDs: [String]
    /// Aggregate workspace-list connection status.
    public var workspaceListStatus: String
    /// Paged workspace rows used by the verifier UI for scrolling evidence.
    public var pages: [[MobileDeleteComputersVerificationWorkspace]]
}
#endif
