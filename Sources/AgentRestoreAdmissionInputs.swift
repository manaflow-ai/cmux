import Foundation

struct AgentRestoreAdmissionInputs: Sendable {
    let workspaceID: UUID
    let surfaceID: UUID
    let kind: String
    let sessionID: String
    let recordSessionID: String
    let codexHome: String?
    let waitForChange: Bool
    let launchLeasePending: Bool
}
