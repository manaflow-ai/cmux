import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("Agent restore relay authorization")
struct AgentRestoreRelayAuthorizationTests {
    @Test("admission and release require in-workspace selectors", arguments: [
        "agent.restore.admit", "agent.restore.release",
    ])
    func restoreSelectors(method: String) {
        let policy = RemoteRelayAuthorizationPolicy()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let parameters = [
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
        ]
        #expect(policy.validate(
            method: method,
            parameters: parameters,
            ownerWorkspaceID: workspaceID,
            surfaceIDs: [surfaceID]
        ) == .allowed)

        #expect(policy.validate(
            method: method,
            parameters: ["surface_id": surfaceID.uuidString],
            ownerWorkspaceID: workspaceID,
            surfaceIDs: [surfaceID]
        ) == .denied(
            code: "remote_relay_workspace_denied",
            message: "Relay method requires an explicit workspace selector"
        ))
        #expect(policy.validate(
            method: method,
            parameters: ["workspace_id": workspaceID.uuidString],
            ownerWorkspaceID: workspaceID,
            surfaceIDs: [surfaceID]
        ) == .denied(
            code: "remote_relay_surface_denied",
            message: "Relay method requires an explicit surface selector"
        ))
        #expect(policy.validate(
            method: method,
            parameters: parameters,
            ownerWorkspaceID: UUID(),
            surfaceIDs: [surfaceID]
        ) == .denied(
            code: "remote_relay_workspace_denied",
            message: "Relay request targets a different workspace"
        ))
        #expect(policy.validate(
            method: method,
            parameters: parameters,
            ownerWorkspaceID: workspaceID,
            surfaceIDs: [UUID()]
        ) == .denied(
            code: "remote_relay_surface_denied",
            message: "Relay request targets a surface outside its workspace"
        ))
    }
}
