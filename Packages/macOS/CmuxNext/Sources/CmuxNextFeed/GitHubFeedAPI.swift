public import Foundation

/// The API calls needed by the local GitHub poster.
public nonisolated protocol GitHubFeedAPI: Sendable {
    func notifications(etag: String?) async throws -> GitHubAPIResponse<[GitHubNotification]>
    func reviewRequests(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]>
    /// Returns open pull requests authored by the user whose checks are failing.
    func failingChecks(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]>
    /// Returns open issues and pull requests assigned to the user (Find Work).
    func assignedWork(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]>
}

public extension GitHubFeedAPI {
    /// A compatibility default keeps small test and host adapters source-only.
    func failingChecks(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]> {
        GitHubAPIResponse(value: [])
    }

    /// A compatibility default keeps small test and host adapters source-only.
    func assignedWork(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]> {
        GitHubAPIResponse(value: [])
    }
}
