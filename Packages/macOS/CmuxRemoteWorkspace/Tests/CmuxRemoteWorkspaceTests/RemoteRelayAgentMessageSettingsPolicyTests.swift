import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// `agent.message.settings` turns agent messages off or on for a local
/// surface or workspace. A remote session has no product need for it, so it
/// stays off the relay allowlist, even for a surface the session owns.
@Suite("Remote relay agent message settings")
struct RemoteRelayAgentMessageSettingsPolicyTests {
    @Test("agent.message.settings is never forwarded, even for an owned surface")
    func settingsMethodIsDenied() throws {
        let surface = UUID()
        let request: [String: Any] = [
            "id": "settings",
            "method": "agent.message.settings",
            "params": ["surface_id": surface.uuidString, "enabled": false],
        ]
        let line = try JSONSerialization.data(withJSONObject: request)
        let verdict = RemoteRelayCommandPolicy().evaluate(
            commandLine: line,
            workspaceAliases: [:],
            surfaceAliases: [surface: surface]
        )
        guard case .deny = verdict else {
            Issue.record("agent.message.settings was allowed through the relay")
            return
        }
        #expect(RemoteRelayCommandPolicy().permittedMethods(from: ["agent.message.settings"]).isEmpty)
    }
}
