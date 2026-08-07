import CmuxControlSocket
import Foundation

extension CMUXCLI {
    /// Private wire guard shared by every visible mutation emitted for one
    /// hook event. The app revalidates it when each queued mutation applies.
    func agentMutationGuard(
        key: String,
        sessionID: String?,
        expectedPIDKey: String?,
        expectedPID: Int?,
        expectedProcessIdentity: AgentHookProcessIdentity?
    ) -> ControlSidebarAgentMutationGuard? {
        guard let key = normalizedAgentLifecycleSessionID(key) else { return nil }
        if let sessionID = normalizedAgentLifecycleSessionID(sessionID) {
            guard expectedPIDKey == nil,
                  expectedPID == nil,
                  expectedProcessIdentity == nil else {
                return nil
            }
            return .session(statusKey: key, sessionID: sessionID)
        }
        guard let expectedPIDKey = normalizedAgentLifecycleSessionID(expectedPIDKey),
              let expectedPID,
              expectedPID > 0,
              expectedPID <= Int(Int32.max),
              let expectedProcessIdentity,
              expectedProcessIdentity.pid == expectedPID else {
            return nil
        }
        return .process(
            statusKey: key,
            pidKey: expectedPIDKey,
            pid: Int32(expectedPID),
            startSeconds: expectedProcessIdentity.startSeconds,
            startMicroseconds: expectedProcessIdentity.startMicroseconds
        )
    }

    func agentMutationGuardOptions(_ guardValue: ControlSidebarAgentMutationGuard) -> String {
        switch guardValue {
        case let .session(statusKey, sessionID):
            return " --expected-agent-key=\(socketQuote(statusKey))"
                + " --expected-agent-session-id=\(socketQuote(sessionID))"
        case let .process(statusKey, pidKey, pid, seconds, microseconds):
            return " --expected-agent-key=\(socketQuote(statusKey))"
                + " --expected-agent-pid-key=\(socketQuote(pidKey))"
                + " --expected-agent-pid=\(pid)"
                + " --expected-agent-pid-start-seconds=\(seconds)"
                + " --expected-agent-pid-start-microseconds=\(microseconds)"
        }
    }

    func setAgentPID(
        client: SocketClient,
        key: String,
        pid: Int,
        workspaceId: String,
        surfaceId: String?,
        expectedLifecycleSessionId: String? = nil,
        expectedProcessIdentity: AgentHookProcessIdentity? = nil
    ) {
        if let expectedProcessIdentity,
           expectedProcessIdentity.pid != pid {
            return
        }
        var command = "set_agent_pid \(key) \(pid) --tab=\(workspaceId)\(socketPanelOption(surfaceId))"
        if let expectedLifecycleSessionId = normalizedAgentLifecycleSessionID(
            expectedLifecycleSessionId
        ) {
            command += " --session-id=\(socketQuote(expectedLifecycleSessionId))"
        }
        if let expectedProcessIdentity {
            command += " --expected-pid-start-seconds=\(expectedProcessIdentity.startSeconds)"
            command += " --expected-pid-start-microseconds=\(expectedProcessIdentity.startMicroseconds)"
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
        expectedPID: Int? = nil,
        expectedProcessIdentity: AgentHookProcessIdentity? = nil
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
            if let expectedProcessIdentity,
               expectedProcessIdentity.pid != expectedPID {
                return
            }
            command += " --expected-pid-key=\(socketQuote(expectedPIDKey))"
            command += " --expected-pid=\(expectedPID)"
            if let expectedProcessIdentity {
                command += " --expected-pid-start-seconds=\(expectedProcessIdentity.startSeconds)"
                command += " --expected-pid-start-microseconds=\(expectedProcessIdentity.startMicroseconds)"
            }
        } else if expectedProcessIdentity != nil {
            return
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
