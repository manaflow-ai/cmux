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
    /// A blocking monitor or known wait command parks the turn on a wakeup.
    static func waitsOnDeterministicEvent(toolName: String?, toolInput: Any?) -> Bool {
        let tool = toolName?.lowercased() ?? ""
        let input = toolInput as? [String: Any] ?? [:]
        if tool == "monitor" { return true }
        if tool == "taskoutput" {
            // Nonblocking probes return immediately, so only a blocking read
            // should hold the hourglass. Claude defaults `block` to true.
            return input["block"] as? Bool != false
        }
        guard ["bash", "shell", "exec_command"].contains(tool),
              let command = input["command"] as? String ?? input["cmd"] as? String else { return false }
        // Match executable positions, not prose or arguments mentioning a
        // wait. A shell loop is waiting only when it contains a real sleep.
        let executable = #"(?:^|[;\n]|&&|\|\||\bdo\s+)\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*(?:[^\s;]+/)?"#
        let wait = #"(?:glaeda-gh\s+wait\b|gh\s+run\s+watch\b|sleep\s+(?:\d|\$)|watch\s+)"#
        if command.range(of: executable + wait, options: .regularExpression) != nil { return true }
        let checks = #"gh\s+pr\s+checks\b[^;\n]*(?:--watch\b|(?:^|\s)-w(?:\s|$))"#
        return command.range(of: executable + checks, options: .regularExpression) != nil
    }

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
