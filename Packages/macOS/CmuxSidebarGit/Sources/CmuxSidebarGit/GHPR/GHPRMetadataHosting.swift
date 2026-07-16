public import Foundation

/// App composition seam for GHPR metadata reads, projection writes, and refresh state.
@MainActor
public protocol GHPRMetadataHosting: AnyObject {
    var ghprConfiguration: GHPRConfiguration { get }
    func trackedGHPRPullRequests() -> [GHPRTrackedPullRequest]
    func applyGHPRBadges(_ badges: [GHPRBadge], workspaceId: UUID)
    func clearGHPRBadges(workspaceId: UUID)
    func reconcileGHPRBadges(trackedWorkspaceIds: Set<UUID>)
    func clearAllGHPRBadges()
    func ghprRefreshStateDidChange(_ state: GHPRRefreshState)
}
