public import Foundation

/// The outcome of one panel's pull-request refresh.
public struct WorkspacePullRequestRefreshResult: Sendable {
    /// How the lookup resolved.
    public enum Resolution: Sendable {
        /// The directory has no GitHub remote; a PR badge is not applicable.
        case unsupportedRepository
        /// No pull request exists for the branch.
        case notFound
        /// A pull request was found.
        case resolved(WorkspacePullRequestResolvedItem)
        /// The lookup failed transiently (network/auth); retry later and keep
        /// any existing badge.
        case transientFailure
    }

    /// Correlation id of the owning workspace.
    public let workspaceId: UUID
    /// Correlation id of the owning panel.
    public let panelId: UUID
    /// How the lookup resolved.
    public let resolution: Resolution
    /// Whether the resolution came from cached repository data (a follow-up
    /// pass may bypass the cache for freshness).
    public let usedCachedRepoData: Bool

    /// Creates a refresh result.
    public init(workspaceId: UUID, panelId: UUID, resolution: Resolution, usedCachedRepoData: Bool) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.resolution = resolution
        self.usedCachedRepoData = usedCachedRepoData
    }
}
