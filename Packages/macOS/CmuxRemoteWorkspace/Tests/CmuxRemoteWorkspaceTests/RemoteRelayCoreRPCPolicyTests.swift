import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("Remote relay core RPC scope")
struct RemoteRelayCoreRPCPolicyTests {
    private let owner = UUID()
    private let surface = UUID()

    @Test("malformed selectors retain the correct workspace or surface denial code", arguments: [
        ("workspace_id", "remote_relay_workspace_denied"),
        ("surface_id", "remote_relay_surface_denied"),
        ("terminal_id", "remote_relay_surface_denied")
    ])
    func malformedSelectorDenialCode(key: String, code: String) {
        let malformedValues: [Any] = [NSNull(), 17, true, [owner.uuidString], ["id": owner.uuidString], "invalid"]
        for value in malformedValues {
            var params: [String: Any] = ["workspace_id": owner.uuidString, "surface_id": surface.uuidString]
            params[key] = value
            #expect(decision("surface.read_text", params) == .denied(code: code, message: "Relay selector is invalid"))
            if key == "workspace_id" {
                #expect(decision("workspace.list", [key: value]) == .denied(code: code, message: "Relay selector is invalid"))
            }
        }
    }

    @Test("capabilities filter exact method names without adding unsupported grants")
    func capabilityDiscovery() {
        let methods = RemoteRelayCommandPolicy().permittedMethods(from: [
            "system.ping", "workspace.list", "surface.send_text", "system.capabilities",
            "system.exec", "system.command_spec", "workspace.create", "surface.respawn", "browser.open",
            "workspace.list.future", "ping", "capabilities"
        ])
        #expect(methods == ["system.ping", "workspace.list", "surface.send_text", "system.capabilities"])
        #expect(decision("surface.send_text", [:]) != .allowed)
        #expect(decision("surface.send_text", [
            "workspace_id": owner.uuidString, "surface_id": UUID().uuidString, "text": "id\n"
        ]) != .allowed)
    }

    @Test("workspace discovery defaults only to authenticated provenance")
    func workspaceDiscovery() {
        #expect(decision("workspace.list", [:]) == .allowed)
        #expect(decision("workspace.list", ["workspace_id": owner.uuidString]) == .allowed)
        #expect(decision("workspace.list", ["workspace_id": UUID().uuidString]) != .allowed)
    }

    @Test("core probes do not accept selectors or command parameters", arguments: [
        "system.ping", "system.capabilities", "workspace.list"
    ])
    func rejectsExtraAuthority(method: String) throws {
        let values: [[String: Any]] = [
            ["workspace_id": "workspace:1"], ["workspace_id": ""],
            ["workspace_id": 42], ["workspace_id": [owner.uuidString]],
            ["workspace_id": ["workspace_id": owner.uuidString]],
            ["preferred_workspace_id": owner.uuidString],
            ["surface_id": surface.uuidString], ["surface_id": UUID().uuidString],
            ["terminal_id": surface.uuidString], ["tab_id": owner.uuidString],
            ["workspace_ids": [owner.uuidString]], ["surface_ids": [surface.uuidString]],
            ["tab_id_groups": [[owner.uuidString]]],
            ["target_workspace_id": owner.uuidString],
            ["metadata": ["workspace_id": owner.uuidString]],
            ["metadata": [["surface_ids": [surface.uuidString]]]],
            ["_cmux_remote_workspace_id": UUID().uuidString]
        ]
        for params in values {
            #expect(decision(method, params) != .allowed)
        }
        for key in ["command", "initial_command", "initial_input", "tmux_start_command", "pane_start_command",
                    "cwd", "environment", "remote_context", "remote_pty_session_id"] {
            let attempts: [[String: Any]] = [[key: "id"], ["metadata": [[key: "id"]]]]
            for params in attempts {
                #expect(decision(method, params) != .allowed)
                let request = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
                #expect(RemoteRelayCommandPolicy().evaluate(commandLine: request,
                    workspaceAliases: [:], surfaceAliases: [:]) != .allow)
            }
        }
    }

    @Test("bare RPC aliases and local execution remain denied", arguments: [
        "ping", "capabilities", "system.exec", "system.command_spec", "system.tree",
        "workspace.create", "workspace.close", "surface.respawn", "surface.send_key", "browser.open", "future.read"
    ])
    func unsupportedMethods(method: String) {
        #expect(decision(method, [:]) != .allowed)
    }

    @Test("remote reconnect remains withheld until its surface execution is scoped")
    func reconnectIsDenied() {
        #expect(decision("workspace.remote.reconnect", [
            "workspace_id": owner.uuidString,
            "surface_id": surface.uuidString,
        ]) == .denied(code: "remote_relay_method_denied", message: "Relay method is not permitted"))
    }

    private func decision(_ method: String, _ parameters: [String: Any]) -> RemoteRelayAuthorizationPolicy.Decision {
        RemoteRelayAuthorizationPolicy().validate(method: method, parameters: parameters,
            ownerWorkspaceID: owner, surfaceIDs: [surface])
    }
}
