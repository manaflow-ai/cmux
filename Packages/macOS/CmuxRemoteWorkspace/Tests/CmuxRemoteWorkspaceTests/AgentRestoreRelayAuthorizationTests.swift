import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("Agent restore relay authorization")
struct AgentRestoreRelayAuthorizationTests {
    @Test("admission and release remain withheld until session state is owner-scoped", arguments: [
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
        ) == .denied(
            code: "remote_relay_method_denied",
            message: "Relay method is not permitted"
        ))
    }
}
