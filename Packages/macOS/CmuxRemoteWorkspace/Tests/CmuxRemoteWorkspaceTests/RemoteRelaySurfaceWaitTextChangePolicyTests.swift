import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// `surface.wait_text_change` holds a relay request open for up to ten
/// minutes and reads terminal text; no remote flow needs it, so it stays off
/// the allowlist even for a surface the session owns.
@Suite("Remote relay terminal text wait")
struct RemoteRelaySurfaceWaitTextChangePolicyTests {
    @Test func waitTextChangeIsDeniedForAnOwnedSurface() throws {
        let workspace = UUID()
        let surface = UUID()
        let request: [String: Any] = [
            "id": "wait",
            "method": "surface.wait_text_change",
            "params": ["workspace_id": workspace.uuidString, "surface_id": surface.uuidString, "timeout_ms": 1_000],
        ]
        let line = try JSONSerialization.data(withJSONObject: request)
        let verdict = RemoteRelayCommandPolicy().evaluate(
            commandLine: line,
            workspaceAliases: [workspace: workspace],
            surfaceAliases: [surface: surface]
        )
        guard case .deny = verdict else {
            Issue.record("surface.wait_text_change was allowed through the relay")
            return
        }
        #expect(RemoteRelayCommandPolicy().permittedMethods(from: ["surface.wait_text_change"]).isEmpty)
    }
}
