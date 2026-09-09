import Foundation

struct AgentWaitResult: Sendable, Equatable {
    let status: AgentWaitStatus
    let until: AgentWaitUntil
    let state: AgentLifecyclePublicState
    let agent: String
    let sessionID: String?
    let workspaceID: UUID
    let surfaceID: UUID
    let paneID: UUID?

    var payload: [String: Any] {
        [
            "status": status.rawValue,
            "until": until.rawValue,
            "state": state.rawValue,
            "agent": agent,
            "session_id": sessionID ?? NSNull(),
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
            "pane_id": paneID?.uuidString ?? NSNull(),
        ]
    }
}
