import CmuxControlSocket
import Foundation

extension TerminalController {
    /// `agent.hibernate`: hibernate one named agent now. Runs on the socket
    /// worker because the teardown awaits a transcript snapshot and a fresh
    /// process census before it commits.
    nonisolated func agentHibernateResponse(_ request: ControlRequest) async -> String {
        let target: (workspaceId: UUID?, panelId: UUID)
        switch await agentHibernationTarget(request) {
        case .success(let resolved): target = resolved
        case .failure(let response): return response.body
        }
        let index = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots()
        let refusal = await AgentHibernationController.shared.hibernateNow(
            workspaceId: target.workspaceId,
            panelId: target.panelId,
            index: index
        )
        if let refusal {
            return Self.v2Encoder.error(id: request.id, code: refusal.rawValue, message: refusal.message)
        }
        return Self.v2Encoder.response(
            id: request.id,
            .ok(.object([
                "surface_id": .string(target.panelId.uuidString),
                "hibernated": .bool(true),
            ]))
        )
    }

    /// `agent.wake`: resume one hibernated agent in place, without focusing it.
    nonisolated func agentWakeResponse(_ request: ControlRequest) async -> String {
        let target: (workspaceId: UUID?, panelId: UUID)
        switch await agentHibernationTarget(request) {
        case .success(let resolved): target = resolved
        case .failure(let response): return response.body
        }
        let refusal = await v2MainAsync {
            AgentHibernationController.shared.wakeNow(
                workspaceId: target.workspaceId,
                panelId: target.panelId
            )
        }
        if let refusal {
            return Self.v2Encoder.error(id: request.id, code: refusal.rawValue, message: refusal.message)
        }
        return Self.v2Encoder.response(
            id: request.id,
            .ok(.object([
                "surface_id": .string(target.panelId.uuidString),
                "woke": .bool(true),
            ]))
        )
    }

    struct AgentHibernationTargetError: Error {
        let body: String
    }

    /// The surface named by `surface_id` (a UUID or ref) and an optional
    /// `workspace_id`. Relayed requests are refused: hibernation acts on local
    /// processes.
    private nonisolated func agentHibernationTarget(
        _ request: ControlRequest
    ) async -> Result<(workspaceId: UUID?, panelId: UUID), AgentHibernationTargetError> {
        let relayError = await v2MainAsync {
            self.controlRemoteRelayDispatchError(method: request.method, params: request.params)
        }
        if let relayError {
            return .failure(AgentHibernationTargetError(body: Self.v2Encoder.response(id: request.id, relayError)))
        }
        let params = request.params.mapValues(\.foundationObject)
        guard let panelId = v2UUID(params, "surface_id") else {
            return .failure(AgentHibernationTargetError(body: Self.v2Encoder.error(
                id: request.id,
                code: "invalid_params",
                message: String(
                    localized: "socket.agentHibernation.surfaceRequired",
                    defaultValue: "Missing or invalid surface_id"
                )
            )))
        }
        return .success((v2UUID(params, "workspace_id"), panelId))
    }
}
