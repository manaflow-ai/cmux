import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("Remote relay viewport authorization")
struct RemoteRelayViewportAuthorizationTests {
    @Test("viewport mutations accept only exact selectors owned by the relay",
          arguments: ["terminal.viewport.set", "terminal.viewport.reset"])
    func viewportSelectors(method: String) {
        let policy = RemoteRelayAuthorizationPolicy()
        let owner = UUID()
        let surface = UUID()
        let target: [String: Any] = [
            "workspace_id": owner.uuidString,
            "surface_id": surface.uuidString,
            "columns": 20,
            "rows": 6
        ]
        func validate(_ parameters: [String: Any]) -> RemoteRelayAuthorizationPolicy.Decision {
            policy.validate(
                method: method, parameters: parameters,
                ownerWorkspaceID: owner, surfaceIDs: [surface]
            )
        }
        #expect(validate(target) == .allowed)

        var foreignWorkspace = target
        foreignWorkspace["workspace_id"] = UUID().uuidString
        #expect(validate(foreignWorkspace) == .denied(
            code: "remote_relay_workspace_denied",
            message: "Relay request targets a different workspace"
        ))

        var foreignSurface = target
        foreignSurface["surface_id"] = UUID().uuidString
        #expect(validate(foreignSurface) == .denied(
            code: "remote_relay_surface_denied",
            message: "Relay request targets a surface outside its workspace"
        ))

        // Provenance and aliases cannot substitute for the exact keys read by
        // the viewport handler, which otherwise falls back to focused routing.
        var missingWorkspace = target
        missingWorkspace.removeValue(forKey: "workspace_id")
        missingWorkspace[RemoteRelayAuthorizationPolicy.remoteWorkspaceIDKey] = owner.uuidString
        #expect(validate(missingWorkspace) == .denied(
            code: "remote_relay_workspace_denied",
            message: "Relay method requires an explicit workspace selector"
        ))
        missingWorkspace["preferred_workspace_id"] = owner.uuidString
        #expect(validate(missingWorkspace) == .denied(
            code: "remote_relay_workspace_denied",
            message: "Relay viewport methods require an explicit workspace_id selector"
        ))

        var missingSurface = target
        missingSurface.removeValue(forKey: "surface_id")
        #expect(validate(missingSurface) == .denied(
            code: "remote_relay_surface_denied",
            message: "Relay method requires an explicit surface selector"
        ))
        missingSurface["preferred_surface_id"] = surface.uuidString
        #expect(validate(missingSurface) == .denied(
            code: "remote_relay_surface_denied",
            message: "Relay viewport methods require an explicit surface_id selector"
        ))
    }
}
