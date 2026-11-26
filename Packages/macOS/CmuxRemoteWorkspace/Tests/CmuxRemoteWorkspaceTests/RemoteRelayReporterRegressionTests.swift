import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("GHSA reporter selector regressions")
struct RemoteRelayReporterRegressionTests {
    private let owner = UUID()
    private let remoteSurface = UUID()
    private let localSurface = UUID()

    @Test("terminal_id cannot bypass ownership using an unrelated owned selector")
    func terminalAliasBypass() {
        let params: [String: Any] = [
            "preferred_workspace_id": owner.uuidString,
            "terminal_id": localSurface.uuidString,
            "text": "touch /tmp/pwned"
        ]
        #expect(decision("surface.send_text", params) != .allowed)
        #expect(decision("surface.send_key", params.merging(["key": "Enter"]) { _, new in new }) != .allowed)
    }

    @Test("an owned decoy does not authorize irrelevant routing", arguments: [
        "preferred_workspace_id", "target_surface_id", "tab_id", "target_terminal_id"
    ])
    func irrelevantRouting(key: String) {
        let params: [String: Any] = [
            "workspace_id": owner.uuidString,
            "surface_id": remoteSurface.uuidString,
            key: localSurface.uuidString,
            "text": "echo scoped"
        ]
        #expect(decision("surface.send_text", params) != .allowed)
    }

    @Test("unknown methods remain denied even with owned selectors")
    func unknownMethod() {
        #expect(decision("future.execute", [
            "workspace_id": owner.uuidString,
            "surface_id": remoteSurface.uuidString
        ]) != .allowed)
    }

    @Test("unknown parameters cannot become future implicit selectors", arguments: ["target", "selector", "metadata"])
    func unknownParameters(key: String) throws {
        let params: [String: Any] = [
            "workspace_id": owner.uuidString,
            "surface_id": remoteSurface.uuidString,
            "text": "echo scoped",
            key: ["id": localSurface.uuidString]
        ]
        #expect(decision("surface.send_text", params) != .allowed)
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "unknown-parameter", "method": "surface.send_text", "params": params
        ])
        #expect(RemoteRelayCommandPolicy().evaluate(commandLine: data,
            workspaceAliases: [:], surfaceAliases: [:]) != .allow)
    }

    @Test("container values cannot masquerade as exact terminal selectors")
    func malformedSelectorContainers() {
        let values: [Any] = [["id": remoteSurface.uuidString], [remoteSurface.uuidString], 17, NSNull()]
        for value in values {
            let params: [String: Any] = ["workspace_id": owner.uuidString, "terminal_id": value]
            #expect(decision("surface.read_selection", params) != .allowed)
        }
    }

    @Test("removing live ownership invalidates a previously authorized selector")
    func revokedOwnership() {
        let policy = RemoteRelayAuthorizationPolicy()
        let params: [String: Any] = [
            "workspace_id": owner.uuidString,
            "surface_id": remoteSurface.uuidString,
            "text": "echo scoped"
        ]
        #expect(decision("surface.send_text", params) == .allowed)
        #expect(policy.validate(method: "surface.send_text", parameters: params,
            ownerWorkspaceID: owner, surfaceIDs: []) != .allowed)
    }

    private func decision(_ method: String, _ params: [String: Any]) -> RemoteRelayAuthorizationPolicy.Decision {
        RemoteRelayAuthorizationPolicy().validate(method: method, parameters: params,
            ownerWorkspaceID: owner, surfaceIDs: [remoteSurface])
    }
}
