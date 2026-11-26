import CmuxSurfaceCatalogModel
import Foundation

/// Immutable capture for the pure current-work reduction; never persisted as a graph.
public struct CurrentWorkInput: Sendable {
    public init(
        export: SurfaceCatalogExport,
        observedAt: Date,
        workspaces: [UUID: WorkspaceFacts],
        agentsByPanelID: [UUID: [CurrentWorkSnapshot.Agent]],
        unreadPanelIDs: Set<UUID>,
        agentOwnerAvailable: Bool
    ) {
        self.export = export
        self.observedAt = observedAt
        self.workspaces = workspaces
        self.agentsByPanelID = agentsByPanelID
        self.unreadPanelIDs = unreadPanelIDs
        self.agentOwnerAvailable = agentOwnerAvailable
    }

    public var export: SurfaceCatalogExport
    public var observedAt: Date
    public var workspaces: [UUID: WorkspaceFacts]
    public var agentsByPanelID: [UUID: [CurrentWorkSnapshot.Agent]]
    public var unreadPanelIDs: Set<UUID>
    public var agentOwnerAvailable: Bool

    public struct WorkspaceFacts: Sendable {
        public init(
            projectRoot: String?,
            unreadCount: Int,
            notificationID: UUID?,
            pullRequests: [CurrentWorkSnapshot.PullRequest]
        ) {
            self.projectRoot = projectRoot
            self.unreadCount = unreadCount
            self.notificationID = notificationID
            self.pullRequests = pullRequests
        }

        public var projectRoot: String?
        public var unreadCount: Int
        public var notificationID: UUID?
        public var pullRequests: [CurrentWorkSnapshot.PullRequest]
    }
}
