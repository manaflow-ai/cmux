/// Resolves launch evidence without turning an incomplete observation into a failed restore.
public struct AgentRestoreEvidencePolicy: Sendable {
    /// The next action for the operation that still owns the saved restore intent.
    public enum Decision: Equatable, Sendable {
        /// Current evidence permits claiming a single launch.
        case claimLaunch
        /// A verified live owner must remain the only writer.
        case observeOwner
        /// Refresh evidence after a process, filesystem, or bounded observation event.
        case refreshEvidence
    }

    /// Creates a stateless admission policy.
    public init() {}

    /// Combines process identity and the provider's writer-lock evidence.
    ///
    /// - Parameters:
    ///   - hasLiveOwner: A currently validated process generation owns the session.
    ///   - indexComplete: The kind-specific ownership scan completed.
    ///   - writerLock: Codex's lock in the exact launch account, or nil for other providers.
    /// - Returns: The next recovery action; unavailable evidence never authorizes a duplicate.
    public func decision(
        hasLiveOwner: Bool,
        indexComplete: Bool,
        writerLock: CodexWriterLockInspection.State?
    ) -> Decision {
        if hasLiveOwner { return .observeOwner }
        switch writerLock {
        case .available:
            return .claimLaunch
        case .active, .changing, .unavailable:
            return .refreshEvidence
        case nil:
            return indexComplete ? .claimLaunch : .refreshEvidence
        }
    }
}
