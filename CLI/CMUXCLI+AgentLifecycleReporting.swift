import Foundation

extension CMUXCLI {
    func setAgentLifecycle(
        client: SocketClient,
        key: String,
        lifecycle: AgentHibernationLifecycleState,
        workspaceId: String,
        surfaceId: String?,
        sessionId: String?
    ) {
        guard Self.allowedAgentLifecycleStatusKeys.contains(key) else {
            cliWriteStderr("Warning: unsupported agent lifecycle key\n")
            return
        }

        var command = "set_agent_lifecycle \(key) \(lifecycle.rawValue) --tab=\(workspaceId)\(socketPanelOption(surfaceId))"
        if let sessionId = normalizedAgentLifecycleSessionID(sessionId) {
            command += " --session-id=\(socketQuote(sessionId))"
        }
        do {
            _ = try sendV1Command(command, client: client)
        } catch {
            cliWriteStderr("Warning: failed to set agent lifecycle\n")
        }
    }

    private func normalizedAgentLifecycleSessionID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
