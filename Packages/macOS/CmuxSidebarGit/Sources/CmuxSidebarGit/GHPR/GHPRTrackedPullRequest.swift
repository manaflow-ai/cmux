public import Foundation

/// The first pull request displayed for one workspace, matching the historical GHPR contract.
public struct GHPRTrackedPullRequest: Equatable, Sendable {
    public let workspaceId: UUID
    public let reference: GHPRPullRequestReference

    public init(workspaceId: UUID, reference: GHPRPullRequestReference) {
        self.workspaceId = workspaceId
        self.reference = reference
    }
}
