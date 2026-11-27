import CmuxCloud
import Foundation

extension TerminalController {
    /// `vm.agent_updates_get {id}` and `vm.agent_updates_set {id, agent_updates}`
    /// behind `cmux vm agent-updates`. Every entrypoint (the CLI, the machine
    /// menu through the CLI) changes the setting through this one path.
    nonisolated func socketWorkerCloudAgentUpdatesResponse(method: String, id: Any?, params: [String: Any]) -> String {
        guard let vmId = Self.socketWorkerString(params["id"]), !vmId.isEmpty else {
            let format = String(
                localized: "socket.cloudVM.agentUpdates.idRequired",
                defaultValue: "%@ requires `id`. Run `cmux vm ls` to find one."
            )
            return v2Error(id: id, code: "invalid_params", message: String(format: format, method))
        }
        if method == "vm.agent_updates_get" {
            return v2CloudCall(id: id, method: method, params: params) {
                let vm = try await VMClient.shared.status(id: vmId)
                return Self.socketWorkerAgentUpdatesPayload(id: vmId, setting: vm.agentUpdates ?? .image, note: nil)
            }
        }
        guard let setting = CloudAgentUpdates(wireValue: params["agent_updates"]) else {
            return v2Error(
                id: id,
                code: "invalid_params",
                message: String(
                    localized: "socket.cloudVM.agentUpdates.invalid",
                    defaultValue: "vm.agent_updates_set `agent_updates` must be latest or image."
                )
            )
        }
        return v2CloudCall(id: id, method: method, params: params, timeoutSeconds: 60) {
            let stored = try await VMClient.shared.setAgentUpdates(id: vmId, setting: setting)
            let note = await Self.socketWorkerAgentUpdatesNetworkNote(id: vmId, setting: stored)
            return Self.socketWorkerAgentUpdatesPayload(id: vmId, setting: stored, note: note)
        }
    }

    /// The note for a machine whose network policy blocks a host the updates
    /// reach. Best effort: an unreadable policy leaves the note out, never
    /// fails the change.
    private nonisolated static func socketWorkerAgentUpdatesNetworkNote(id: String, setting: CloudAgentUpdates) async -> String? {
        guard setting == .latest, let status = try? await VMClient.shared.networkPolicy(id: id) else { return nil }
        return setting.networkNote(for: status.policy, catalog: status.catalog)
    }

    nonisolated static func socketWorkerAgentUpdatesPayload(id: String, setting: CloudAgentUpdates, note: String?) -> [String: Any] {
        var payload: [String: Any] = ["id": id, "agent_updates": setting.rawValue]
        if let note { payload["note"] = note }
        return payload
    }
}
