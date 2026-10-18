import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// `vm.agent_readiness` runs a script on a Cloud machine under the Mac's account
/// and can make it send a key to its provider. A remote session must never reach
/// it through the CLI relay: it has no relay contract, so discovery hides it and
/// every call, with or without parameters, is denied before the local socket.
@Suite("Remote relay: agent readiness stays local")
struct RemoteRelayAgentReadinessPolicyTests {
    private let owner = UUID()
    private let surface = UUID()

    @Test("vm.agent_readiness has no relay contract and is denied", arguments: [
        #"{}"#,
        #"{"id":"vm-1"}"#,
        #"{"id":"vm-1","probe":true}"#,
        #"{"id":"vm-1","agent":"claude","fast":true,"workspace_id":"00000000-0000-0000-0000-000000000001"}"#,
    ])
    func agentReadinessIsDenied(paramsJSON: String) throws {
        let params = try #require(try JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)) as? [String: Any])
        let method = "vm.agent_readiness"
        #expect(RemoteRelayRoutingSchema().parameters(for: method) == nil)
        #expect(!RemoteRelayCommandPolicy().permittedMethods(from: [method, "system.ping"]).contains(method))
        #expect(RemoteRelayAuthorizationPolicy().validate(
            method: method, parameters: params, ownerWorkspaceID: owner, surfaceIDs: [surface]
        ) == .denied(code: "remote_relay_method_denied", message: "Relay method is not permitted"))
        let request = try JSONSerialization.data(withJSONObject: ["id": "r1", "method": method, "params": params])
        #expect(RemoteRelayCommandPolicy().evaluate(
            commandLine: request, workspaceAliases: [owner: owner], surfaceAliases: [surface: surface]
        ) != .allow)
    }
}
