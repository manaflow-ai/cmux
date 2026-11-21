import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// `session_priority.set` changes how hard a local Claude session works (and restarts it), and
/// `get`/`status` expose local workspace state, so a remote session must reach none of them,
/// not even for a workspace it owns.
extension RemoteCLIRelayPolicyTests {
    @Test("session_priority.get/set/status are denied over the relay")
    func sessionPriorityMethodsAreDeniedOverRelay() throws {
        let workspace = UUID()
        let requests: [(id: String, method: String, params: [String: Any])] = [
            ("sp1", "session_priority.set", ["workspace_id": workspace.uuidString, "difficulty": "hard"]),
            ("sp2", "session_priority.get", [:]),
            ("sp3", "session_priority.status", [:]),
        ]
        try withServer(workspaceAliases: [workspace: workspace]) { port, unixServer in
            for request in requests {
                let line = try JSONSerialization.data(withJSONObject: [
                    "id": request.id,
                    "method": request.method,
                    "params": request.params,
                ])
                let exchange = try runPolicyRelayExchange(
                    port: port,
                    relayID: relayID,
                    tokenHex: tokenHex,
                    commandLine: String(decoding: line, as: UTF8.self)
                )
                expectDenial(exchange, unixServer, "\(request.method) \(request.id)")
            }
        }

        let methods = ["session_priority.get", "session_priority.set", "session_priority.status"]
        #expect(RemoteRelayCommandPolicy().permittedMethods(from: methods).isEmpty)
        for method in methods {
            #expect(RemoteRelayAuthorizationPolicy().validate(
                method: method,
                parameters: ["workspace_id": workspace.uuidString, "difficulty": "hard"],
                ownerWorkspaceID: workspace,
                surfaceIDs: []
            ) == .denied(code: "remote_relay_method_denied", message: "Relay method is not permitted"))
        }
    }
}
