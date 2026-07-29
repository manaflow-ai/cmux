import Foundation

extension CMUXCLI {
    func setAgentPID(
        client: SocketClient,
        key: String,
        pid: Int,
        workspaceId: String,
        surfaceId: String?,
        expectedLifecycleSessionId: String? = nil
    ) {
        var command = "set_agent_pid \(key) \(pid) --tab=\(workspaceId)\(socketPanelOption(surfaceId))"
        if let expectedLifecycleSessionId = normalizedAgentLifecycleSessionID(
            expectedLifecycleSessionId
        ) {
            command += " --session-id=\(socketQuote(expectedLifecycleSessionId))"
        }
        _ = try? sendV1Command(command, client: client)
    }

    func setAgentLifecycle(
        client: SocketClient,
        key: String,
        lifecycle: AgentHibernationLifecycleState,
        workspaceId: String,
        surfaceId: String?,
        sessionId: String?,
        startsNewOccupant: Bool = false,
        expectedPIDKey: String? = nil,
        expectedPID: Int? = nil
    ) {
        guard Self.allowedAgentLifecycleStatusKeys.contains(key) else {
            cliWriteStderr("Warning: unsupported agent lifecycle key\n")
            return
        }

        var command = "set_agent_lifecycle \(key) \(lifecycle.rawValue) --tab=\(workspaceId)\(socketPanelOption(surfaceId))"
        if let sessionId = normalizedAgentLifecycleSessionID(sessionId) {
            command += " --session-id=\(socketQuote(sessionId))"
        }
        if startsNewOccupant {
            command += " --new-occupant"
        }
        if let expectedPIDKey = normalizedAgentLifecycleSessionID(expectedPIDKey),
           let expectedPID,
           expectedPID > 0 {
            command += " --expected-pid-key=\(socketQuote(expectedPIDKey))"
            command += " --expected-pid=\(expectedPID)"
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
