import Foundation

struct AgentWaitSurfaceSnapshot: Sendable, Equatable {
    let workspaceID: UUID
    let surfaceID: UUID
    let paneID: UUID?
    let occupant: AgentLifecycleRecord?
    let hasAuthoritativeLiveLifecycle: Bool

    init(
        workspaceID: UUID,
        surfaceID: UUID,
        paneID: UUID?,
        occupant: AgentLifecycleRecord?,
        hasAuthoritativeLiveLifecycle: Bool = true
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.paneID = paneID
        self.occupant = occupant
        self.hasAuthoritativeLiveLifecycle = hasAuthoritativeLiveLifecycle
    }
}
