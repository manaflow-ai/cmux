import Foundation

struct AgentWaitSurfaceSnapshot: Sendable, Equatable {
    let workspaceID: UUID
    let surfaceID: UUID
    let paneID: UUID?
    let occupant: AgentLifecycleRecord?
}
