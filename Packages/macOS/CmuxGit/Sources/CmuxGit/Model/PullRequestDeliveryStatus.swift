public import Foundation

/// The aggregate state of the checks attached to a pull request's head commit.
public enum PullRequestCheckState: String, Equatable, Sendable {
    /// Every check completed successfully.
    case success
    /// At least one check failed.
    case failure
    /// One or more checks are still running.
    case pending
    /// Checks completed without a success or failure conclusion.
    case neutral
    /// The provider returned no usable state.
    case unknown
}

/// A compact count and state summary for pull-request checks.
public struct PullRequestCheckSummary: Equatable, Sendable {
    /// The aggregate state.
    public let state: PullRequestCheckState
    /// Number of checks that completed successfully.
    public let passedCount: Int
    /// Number of checks that completed unsuccessfully.
    public let failedCount: Int
    /// Number of checks that are still running.
    public let pendingCount: Int
    /// Number of checks included in the summary.
    public let totalCount: Int

    /// Creates a check summary.
    public init(
        state: PullRequestCheckState,
        passedCount: Int,
        failedCount: Int,
        pendingCount: Int,
        totalCount: Int
    ) {
        self.state = state
        self.passedCount = passedCount
        self.failedCount = failedCount
        self.pendingCount = pendingCount
        self.totalCount = totalCount
    }
}

/// The aggregate state of a deployment status associated with a pull request.
public enum PullRequestDeploymentState: String, Equatable, Sendable {
    /// The deployment is live and serving traffic.
    case live
    /// The deployment failed.
    case failure
    /// The deployment is being prepared.
    case pending
    /// The deployment is no longer active.
    case inactive
    /// The provider returned no usable state.
    case unknown
}

/// A deployment status surfaced from a pull request's commit statuses.
public struct PullRequestDeploymentSummary: Equatable, Sendable {
    /// Provider label, such as `Vercel` or `Preview`.
    public let name: String
    /// The deployment lifecycle state.
    public let state: PullRequestDeploymentState
    /// Optional provider URL for opening the preview.
    public let url: URL?

    /// Creates a deployment summary.
    public init(name: String, state: PullRequestDeploymentState, url: URL? = nil) {
        self.name = name
        self.state = state
        self.url = url
    }
}

/// The passive CI and deployment details attached to one pull request.
public struct PullRequestDeliveryStatus: Equatable, Sendable {
    /// Check-run aggregate, when GitHub reported checks.
    public let checks: PullRequestCheckSummary?
    /// Deployment-like commit status, when a provider reported one.
    public let deployment: PullRequestDeploymentSummary?

    /// Creates a delivery status.
    public init(
        checks: PullRequestCheckSummary?,
        deployment: PullRequestDeploymentSummary?
    ) {
        self.checks = checks
        self.deployment = deployment
    }
}
