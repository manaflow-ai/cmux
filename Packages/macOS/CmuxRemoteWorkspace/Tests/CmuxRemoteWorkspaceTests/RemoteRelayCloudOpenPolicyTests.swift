import Foundation
import Testing
@testable import CmuxRemoteWorkspace

struct RemoteRelayCloudOpenPolicyTests {
    @Test func cloudOpenActionsPassBothRelayGates() throws {
        for (method, params) in [
            ("vm.base_open", ["kind": "desktop"] as [String: Any]),
            ("vm.open_local", [:]),
            ("vm.open_local", ["id": "vm-example", "force_ssh": true]),
        ] {
            #expect(try commandVerdict(method, params) == .allow)
            #expect(authorization(method, params) == .allowed)
        }
    }

    @Test func credentialsAndOtherCloudOperationsRemainDenied() throws {
        for method in ["vm.attach_info", "vm.cmux_remote_info", "vm.ssh_info", "vm.scp_info",
                       "vm.session_attach_info", "vm.tunnel_config", "vm.create", "vm.destroy", "vm.exec"] {
            #expect(try commandVerdict(method, ["id": "vm-example"]) != .allow)
            #expect(authorization(method, ["id": "vm-example"]) != .allowed)
        }
    }

    @Test func cloudOpenCannotInjectCommandsOrSelectOtherContainers() throws {
        for method in ["vm.base_open", "vm.open_local"] {
            for params: [String: Any] in [
                ["initial_command": "echo injected"],
                ["arguments": ["vm", "exec", "vm-example"]],
                ["workspace_id": UUID().uuidString],
                ["window_id": UUID().uuidString],
                ["target_workspace_id": UUID().uuidString],
                ["environment": ["PATH": "/tmp"]],
            ] {
                #expect(try commandVerdict(method, params) != .allow)
                #expect(authorization(method, params) != .allowed)
            }
        }
    }

    private func commandVerdict(_ method: String, _ params: [String: Any]) throws -> RemoteRelayCommandPolicy.Verdict {
        let data = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        return RemoteRelayCommandPolicy().evaluate(commandLine: data, workspaceAliases: [:], surfaceAliases: [:])
    }

    private func authorization(_ method: String, _ params: [String: Any]) -> RemoteRelayAuthorizationPolicy.Decision {
        RemoteRelayAuthorizationPolicy().validate(
            method: method, parameters: params, ownerWorkspaceID: UUID(), surfaceIDs: []
        )
    }
}
