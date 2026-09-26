import Foundation

extension CMUXCLI {
    /// Restores the shared needs-input status after a completion Stop that
    /// followed an attention request in the same turn.
    func setAgentNeedsInputStatus(
        def: AgentHookDef,
        workspaceId: String,
        surfaceId: String,
        client: SocketClient
    ) {
        let statusValue = agentNeedsInputStatusValue(for: def)
        _ = try? sendV1Command(
            "set_status \(def.statusKey) \(statusValue) --icon=bell.fill --color=#4C8DFF --priority=100 --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
            client: client
        )
    }
}
