public import Foundation

/// A read-only snapshot of one workspace's todo status, as the app target
/// exposes it to ``ControlCommandCoordinator`` through
/// ``ControlWorkspaceTodoContext``.
///
/// Status values cross the seam as their raw wire strings (`todo`, `working`,
/// `needs-attention`, `review`, `done`) so the package does not depend on the
/// app-side `WorkspaceTaskStatus` type.
public struct ControlWorkspaceTodoStatusSnapshot: Sendable, Equatable {
    /// The live signals that drove the inference, echoed in the payload so
    /// callers can see WHY a lane was inferred.
    public struct Signals: Sendable, Equatable {
        /// Whether any agent is waiting on user input.
        public let anyAgentNeedsInput: Bool
        /// Whether any agent is running.
        public let anyAgentRunning: Bool
        /// Whether any sidebar pull request is open.
        public let anyOpenPullRequest: Bool
        /// Whether the workspace has any sidebar pull requests.
        public let hasPullRequests: Bool
        /// Whether every sidebar pull request is merged or closed.
        public let allPullRequestsMergedOrClosed: Bool
        /// Whether any tracked git working tree is dirty.
        public let isGitDirty: Bool

        /// Creates a signals snapshot.
        public init(
            anyAgentNeedsInput: Bool,
            anyAgentRunning: Bool,
            anyOpenPullRequest: Bool,
            hasPullRequests: Bool,
            allPullRequestsMergedOrClosed: Bool,
            isGitDirty: Bool
        ) {
            self.anyAgentNeedsInput = anyAgentNeedsInput
            self.anyAgentRunning = anyAgentRunning
            self.anyOpenPullRequest = anyOpenPullRequest
            self.hasPullRequests = hasPullRequests
            self.allPullRequestsMergedOrClosed = allPullRequestsMergedOrClosed
            self.isGitDirty = isGitDirty
        }
    }

    /// The resolved workspace's identifier.
    public let workspaceID: UUID
    /// The effective status raw value (override while fresh, else inferred).
    public let effective: String
    /// The inferred status raw value.
    public let inferred: String
    /// The manual override's status raw value, if an override is stored.
    public let overrideStatus: String?
    /// The inference recorded when the override was set, if one is stored.
    public let overrideInferredAt: String?
    /// The live signals behind the inference.
    public let signals: Signals

    /// Creates a status snapshot.
    public init(
        workspaceID: UUID,
        effective: String,
        inferred: String,
        overrideStatus: String?,
        overrideInferredAt: String?,
        signals: Signals
    ) {
        self.workspaceID = workspaceID
        self.effective = effective
        self.inferred = inferred
        self.overrideStatus = overrideStatus
        self.overrideInferredAt = overrideInferredAt
        self.signals = signals
    }
}
