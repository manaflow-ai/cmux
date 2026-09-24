import CmuxSurfaceCatalogModel
import Foundation

/// Immutable capture for the pure current-work reduction; never persisted as a graph.
struct CurrentWorkInput: Sendable {
    var export: SurfaceCatalogExport
    var observedAt: Date
    var workspaces: [UUID: WorkspaceFacts]
    var agentsByPanelID: [UUID: [CurrentWorkSnapshot.Agent]]
    var unreadPanelIDs: Set<UUID>
    var agentOwnerAvailable: Bool

    struct WorkspaceFacts: Sendable {
        var projectRoot: String?
        var unreadCount: Int
        var notificationID: UUID?
        var pullRequests: [CurrentWorkSnapshot.PullRequest]
    }
}
