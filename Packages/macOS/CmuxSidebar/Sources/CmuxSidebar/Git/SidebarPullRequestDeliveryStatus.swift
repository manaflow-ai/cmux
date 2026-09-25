public import Foundation

/// The aggregate check state shown beside a pull request in the sidebar.
public enum SidebarPullRequestCheckState: String, Equatable, Sendable {
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

/// The aggregate deployment state shown beside a pull request in the sidebar.
public enum SidebarPullRequestDeploymentState: String, Equatable, Sendable {
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

/// A compact check summary projected into the sidebar UI.
public struct SidebarPullRequestCheckSummary: Equatable, Sendable {
    /// Aggregate state.
    public let state: SidebarPullRequestCheckState
    /// Number of successful checks.
    public let passedCount: Int
    /// Number of failed checks.
    public let failedCount: Int
    /// Number of checks still running.
    public let pendingCount: Int
    /// Total checks included.
    public let totalCount: Int

    /// Creates a check summary.
    public init(
        state: SidebarPullRequestCheckState,
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

/// A deployment provider summary projected into the sidebar UI.
public struct SidebarPullRequestDeploymentSummary: Equatable, Sendable {
    /// Provider label, such as `Vercel` or `Preview`.
    public let name: String
    /// Deployment lifecycle state.
    public let state: SidebarPullRequestDeploymentState
    /// Optional preview URL.
    public let url: URL?

    /// Creates a deployment summary.
    public init(name: String, state: SidebarPullRequestDeploymentState, url: URL? = nil) {
        self.name = name
        self.state = state
        self.url = url
    }
}

/// Passive CI and deployment details rendered under a pull request.
public struct SidebarPullRequestDeliveryStatus: Equatable, Sendable {
    /// Check-run aggregate, when available.
    public let checks: SidebarPullRequestCheckSummary?
    /// Deployment summary, when available.
    public let deployment: SidebarPullRequestDeploymentSummary?

    /// Creates a delivery status.
    public init(
        checks: SidebarPullRequestCheckSummary?,
        deployment: SidebarPullRequestDeploymentSummary?
    ) {
        self.checks = checks
        self.deployment = deployment
    }
}
