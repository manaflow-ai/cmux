import CMUXAgentLaunch
import CmuxControlSocket
import Foundation

extension CMUXCLI {
    /// Removes the private relay-generation suffix before a resume binding
    /// crosses the public surface-resume contract.
    func agentHookResumeSessionID(_ sessionID: String) -> String {
        AgentRelayLifecycle.publicSessionID(sessionID)
    }

    /// Binds a relay-host session (reported, inferred, or surface-derived) to
    /// the exact remote terminal attempt and process generation that emitted it.
    func agentHookRelayLifecycleGeneration(
        sessionID: String,
        environment: [String: String],
        processIdentity: AgentHookProcessIdentity
    ) -> String? {
        AgentRelayLifecycle.inferredGeneration(
            sessionID: sessionID,
            environment: environment,
            pid: processIdentity.pid,
            startSeconds: processIdentity.startSeconds,
            startMicroseconds: processIdentity.startMicroseconds
        )
    }

    /// Validates a relay-generation token carried by a detached Codex monitor.
    /// The monitor already has the token minted by its parent hook, so it must
    /// be preserved rather than wrapped in a second generation suffix.
    func agentHookExistingRelayLifecycleGeneration(
        sessionID: String,
        environment: [String: String]
    ) -> String? {
        AgentRelayLifecycle.existingGeneration(
            sessionID: sessionID,
            environment: environment
        )
    }

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
        // A durable session ID may be reused by a later process generation.
        // When the hook captured that generation, prefer the stronger process
        // guard so deferred teardown cannot authorize against the session ID
        // alone.
        if let expectedProcessIdentity {
            guard let pidKey = normalizedAgentLifecycleSessionID(expectedPIDKey),
                  let expectedPID,
                  expectedPID > 0,
                  expectedPID <= Int(Int32.max),
                  expectedPID == expectedProcessIdentity.pid else {
                return nil
            }
            return .process(
                statusKey: key,
                pidKey: pidKey,
                pid: Int32(expectedPID),
                startSeconds: expectedProcessIdentity.startSeconds,
                startMicroseconds: expectedProcessIdentity.startMicroseconds
            )
        }
        if let sessionID = normalizedAgentLifecycleSessionID(sessionID) {
            // Explicit provider session IDs remain authoritative when the
            // provider's PID cannot be inspected from this host (for example,
            // a test/compatibility hook or an older local integration). When
            // an exact process generation is available the branch above is
            // deliberately stronger; anonymous hooks still fail closed below.
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
        expectedProcessIdentity: AgentHookProcessIdentity? = nil,
        responseTimeout: TimeInterval? = nil,
        deadline: Date? = nil
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
        _ = try? client.send(
            command: command,
            responseTimeout: responseTimeout,
            deadline: deadline
        )
    }

    @discardableResult
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
        expectedProcessIdentity: AgentHookProcessIdentity? = nil,
        requireAcceptedOwner: Bool = false,
        preflightOnly: Bool = false,
        preserveNotifications: Bool = false
    ) -> Bool {
        guard !preflightOnly || requireAcceptedOwner else { return false }
        guard Self.allowedAgentLifecycleStatusKeys.contains(key) else {
            cliWriteStderr("Warning: unsupported agent lifecycle key\n")
            return false
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
                return false
            }
            command += " --expected-pid-key=\(socketQuote(expectedPIDKey))"
            command += " --expected-pid=\(expectedPID)"
            if let expectedProcessIdentity {
                command += " --expected-pid-start-seconds=\(expectedProcessIdentity.startSeconds)"
                command += " --expected-pid-start-microseconds=\(expectedProcessIdentity.startMicroseconds)"
            }
        } else if expectedProcessIdentity != nil {
            return false
        }
        if requireAcceptedOwner {
            command += " --require-accepted"
        }
        if preflightOnly {
            command += " --prepare-only"
        }
        if preserveNotifications {
            // Nested/managed hooks still claim their durable occupant, but
            // must not clear the parent occupant's visible notifications.
            command += " --preserve-notifications"
        }
        do {
            let response = try sendV1Command(command, client: client)
            return requireAcceptedOwner ? response == "OK:1" : true
        } catch {
            cliWriteStderr("Warning: failed to set agent lifecycle\n")
            return false
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
