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
            "system.ping", "workspace.list", "surface.send_text", "terminal.paste", "system.capabilities",
            "system.exec", "system.command_spec", "workspace.create", "surface.respawn", "browser.open",
            "workspace.list.future", "ping", "capabilities"
        ])
        #expect(methods == ["system.ping", "workspace.list", "surface.send_text", "terminal.paste", "system.capabilities"])
        #expect(decision("surface.send_text", [:]) != .allowed)
        #expect(decision("surface.send_text", [
            "workspace_id": owner.uuidString, "surface_id": UUID().uuidString, "text": "id\n"
        ]) != .allowed)
    }

    @Test("terminal paste syntax is narrower than generic terminal input")
    func terminalPasteSyntax() throws {
        let valid: [String: Any] = [
            "workspace_id": owner.uuidString,
            "surface_id": surface.uuidString,
            "text": "hello\nworld",
            "submit_key": "return",
        ]
        #expect(decision("terminal.paste", valid) == .allowed)
        let request = try JSONSerialization.data(withJSONObject: ["method": "terminal.paste", "params": valid])
        #expect(RemoteRelayCommandPolicy().evaluate(
            commandLine: request, workspaceAliases: [:], surfaceAliases: [:]
        ) == .allow)

        for params in [
            ["workspace_id": owner.uuidString, "surface_id": surface.uuidString, "text": "hello"],
            ["workspace_id": owner.uuidString, "surface_id": surface.uuidString, "text": "hello", "submit_key": "enter"],
            ["workspace_id": owner.uuidString, "surface_id": surface.uuidString, "text": 7, "submit_key": "none"],
        ] as [[String: Any]] {
            #expect(decision("terminal.paste", params) != .allowed)
            let invalid = try JSONSerialization.data(withJSONObject: ["method": "terminal.paste", "params": params])
            #expect(RemoteRelayCommandPolicy().evaluate(
                commandLine: invalid, workspaceAliases: [:], surfaceAliases: [:]
            ) != .allow)
        }
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

    @Test("window capture is never reachable from a relay", arguments: [
        "window.record.start", "window.record.stop", "window.record.status",
        "window.record.note", "window.record.list", "window.screenshot"
    ])
    func windowCaptureIsDenied(method: String) {
        // Recording films the local screen and a still photographs it. A relay
        // peer is authorized for the objects of one workspace, not for whatever
        // the local user has on display, so these verbs stay off the allowlist
        // entirely.
        #expect(decision(method, [:]) == .denied(code: "remote_relay_method_denied",
            message: "Relay method is not permitted"))
        #expect(decision(method, ["workspace_id": owner.uuidString]) != .allowed)
        #expect(RemoteRelayCommandPolicy().permittedMethods(from: [method]).isEmpty)
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
