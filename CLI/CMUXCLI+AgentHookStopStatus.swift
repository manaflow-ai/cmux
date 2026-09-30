import Foundation

/// What a running agent is working on, as the sidebar's `set_status --work`
/// option spells it. The CLI does not link the sidebar package, so these raw
/// values are the wire contract with the app's `SidebarAgentWorkState`.
enum AgentSidebarWorkState: String {
    case running
    case subagents
    case waiting
}

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
