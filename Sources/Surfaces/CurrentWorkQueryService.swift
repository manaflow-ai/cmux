import CmuxAgentChat
import CmuxNotifications
import Foundation

/// Captures current owners in one actor turn. Reading never refreshes or discovers work.
@MainActor
struct CurrentWorkQueryService {
    private let catalog: SurfaceCatalog
    private let workspaceOwners: @MainActor (Set<UUID>) -> [UUID: Workspace]
    private let agentRecords: @MainActor () -> [AgentChatSessionRecord]?
    private let unread: @MainActor () -> SidebarUnreadSnapshot
    private let unreadSurfaces: @MainActor () -> Set<SidebarSurfaceUnreadKey>
    private let now: @MainActor () -> Date

    init(
        catalog: SurfaceCatalog,
        workspaceOwners: @escaping @MainActor (Set<UUID>) -> [UUID: Workspace],
        agentRecords: @escaping @MainActor () -> [AgentChatSessionRecord]?,
        unread: @escaping @MainActor () -> SidebarUnreadSnapshot,
        unreadSurfaces: @escaping @MainActor () -> Set<SidebarSurfaceUnreadKey>,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.catalog = catalog
        self.workspaceOwners = workspaceOwners
        self.agentRecords = agentRecords
        self.unread = unread
        self.unreadSurfaces = unreadSurfaces
        self.now = now
    }

    /// Returns a bounded snapshot for an in-process consumer, with no suspension or I/O.
    func read(limit: Int = 100) -> CurrentWorkSnapshot {
        CurrentWorkReducer().reduce(capture(), limit: limit)
    }

    /// Main-actor ownership requires capture here; socket formatting/reduction can run off-main.
    func capture() -> CurrentWorkInput {
        let date = now()
        let timestamp = date.ISO8601Format()
        var export = catalog.export
        let owners = workspaceOwners(Set(export.catalog.projections.map(\.workspaceID)))
        export.projectionIdentities = SurfaceProjectionIdentity.capture(projections: export.catalog.projections, workspacesByID: owners)
        let notifications = unread()
        let unreadKeys = unreadSurfaces()
        var facts: [UUID: CurrentWorkInput.WorkspaceFacts] = [:]
        for (id, workspace) in owners {
            let summary = notifications.summary(forWorkspaceId: id)
            facts[id] = .init(
                projectRoot: workspace.extensionSidebarProjectRootPath,
                unreadCount: summary.unreadCount,
                notificationID: summary.latestNotificationId,
                pullRequests: workspace.sidebarPullRequestsInDisplayOrder().map { pr in
                    .init(number: pr.number, url: pr.url.absoluteString, label: String(pr.label.prefix(2048)), status: pr.status.rawValue,
                          workspaceID: id,
                          freshness: .init(state: pr.isStale ? "stale" : "unknown",
                                           reason: pr.isStale ? "inactive_panel_report" : "owner_has_no_update_timestamp", observedAt: timestamp),
                          evidence: .init(owner: "Workspace.sidebarPullRequests", reference: pr.url.absoluteString, observedAt: timestamp))
                }
            )
        }
        let records = agentRecords()
        var agents: [UUID: [CurrentWorkSnapshot.Agent]] = [:]
        let panelIDs = Set(export.catalog.projections.map(\.panelID))
        for record in records ?? [] {
            guard let raw = record.surfaceID, let panelID = UUID(uuidString: raw), panelIDs.contains(panelID) else { continue }
            let state: String
            switch record.state {
            case .idle: state = record.hasHookLifecycleState ? "idle" : "unknown"
            case .working: state = "working"
            case .needsInput: state = "needs_input"
            case .ended: state = "ended"
            }
            agents[panelID, default: []].append(.init(
                sessionID: record.sessionID, kind: record.agentKind.sourceName, state: state,
                hasHookLifecycleState: record.hasHookLifecycleState, version: record.version,
                lastActivityAt: record.lastActivityAt.ISO8601Format(),
                evidence: .init(owner: "AgentChatSessionRegistry", reference: "\(record.agentKind.sourceName)/\(record.sessionID)@\(record.version)", observedAt: timestamp)
            ))
        }
        // UUID equality alone is insufficient if a stale notification names the
        // same panel under an old workspace. Match the complete current owner pair.
        let unreadPanelIDs = Set(export.catalog.projections.compactMap { projection in
            unreadKeys.contains(.init(workspaceId: projection.workspaceID, surfaceId: projection.panelID)) ? projection.panelID : nil
        })
        return .init(export: export, observedAt: date, workspaces: facts, agentsByPanelID: agents,
                     unreadPanelIDs: unreadPanelIDs, agentOwnerAvailable: records != nil)
    }
}
