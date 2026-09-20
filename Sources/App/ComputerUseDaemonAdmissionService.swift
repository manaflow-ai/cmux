import CmuxControlSocket
import CmuxComputerUseCore
import Foundation

/// Publishes the host's verified setup decision to an exact authenticated helper generation.
struct ComputerUseDaemonAdmissionService: Sendable {
    let paths: ComputerUseRuntimePaths
    let transport: SocketTransport

    /// Both daemon profiles expose this control method. The Codex tool registry
    /// deliberately omits `check_permissions` and requires a broker for tool calls.
    func permissionStatus(at socketURL: URL, peer: AgentPIDProcessIdentity) async -> ComputerUsePermissionStatus? {
        guard let response = await ComputerUseRuntimeService.sendDaemonRequest(
            ["method": "permissions_status"],
            paths: paths, transport: transport, timeout: 2,
            expectedPeerIdentity: peer, socketURL: socketURL
        ), response["ok"] as? Bool == true,
           let result = response["result"] as? [String: Any] else { return nil }
        return ComputerUsePermissionStatus(structuredContent: result)
    }

    func publish(
        phase: ComputerUseRuntimePermissionPhase,
        enabled: Bool,
        to socketURL: URL,
        peer: AgentPIDProcessIdentity
    ) async -> Bool {
        let ready = enabled && phase.isReady
        guard AgentPIDProcessIdentity(pid: peer.pid) == peer,
              let response = await ComputerUseRuntimeService.sendDaemonRequest(
                ["method": "set_external_permission_ready", "args": ["ready": ready]],
                paths: paths,
                transport: transport,
                timeout: 2,
                expectedPeerIdentity: peer,
                socketURL: socketURL
              ) else { return false }
        return response["ok"] as? Bool == true
            && (response["result"] as? [String: Any])?["external_permission_ready"] as? Bool == ready
    }
}
