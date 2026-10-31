import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// `claude_account.switch` respawns a local terminal under another Claude account and types a
/// resume command into the new shell. That is local command execution, so a remote session must
/// never reach it, not even for a workspace and surface it owns.
extension RemoteCLIRelayPolicyTests {
    @Test("claude_account.switch is denied even on an owned surface (local respawn and typed resume)")
    func claudeAccountSwitchIsDeniedOverRelay() throws {
        let workspace = UUID()
        let surface = UUID()
        let requests: [(id: String, params: [String: Any])] = [
            ("ca1", ["workspace_id": workspace.uuidString, "surface_id": surface.uuidString, "account": "work"]),
            ("ca2", ["surface_id": surface.uuidString, "account": "default", "force": true]),
            ("ca3", ["account": "work"]),
        ]
        try withServer(
            workspaceAliases: [workspace: workspace],
            surfaceAliases: [surface: surface]
        ) { port, unixServer in
            for request in requests {
                let line = try JSONSerialization.data(withJSONObject: [
                    "id": request.id,
                    "method": "claude_account.switch",
                    "params": request.params,
                ])
                let exchange = try runPolicyRelayExchange(
                    port: port,
                    relayID: relayID,
                    tokenHex: tokenHex,
                    commandLine: String(decoding: line, as: UTF8.self)
                )
                expectDenial(exchange, unixServer, "claude_account.switch \(request.id)")
            }
        }

        // Relay discovery never advertises it, and the app-side gate refuses it as well.
        #expect(RemoteRelayCommandPolicy().permittedMethods(from: ["claude_account.switch"]).isEmpty)
        #expect(RemoteRelayAuthorizationPolicy().validate(
            method: "claude_account.switch",
            parameters: [
                "workspace_id": workspace.uuidString,
                "surface_id": surface.uuidString,
                "account": "work",
            ],
            ownerWorkspaceID: workspace,
            surfaceIDs: [surface]
        ) == .denied(code: "remote_relay_method_denied", message: "Relay method is not permitted"))
    }
}
