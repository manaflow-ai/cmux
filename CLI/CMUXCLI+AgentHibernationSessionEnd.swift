import Foundation

struct ClaudeHookProcessGeneration: Codable, Equatable {
    let pid: Int
    let startSeconds: Int64
    let startMicroseconds: Int64
}

extension ClaudeHookSessionRecord {
    /// Updates the current process generation and retains a bounded history of
    /// prior generations for delayed lifecycle hooks.
    mutating func updateProcessGeneration(
        pid: Int,
        startIdentity: (seconds: Int64, microseconds: Int64)?
    ) {
        let previousPID = self.pid
        let previousGeneration: ClaudeHookProcessGeneration? = if let previousPID,
            let previousStartSeconds = pidStartSeconds,
            let previousStartMicroseconds = pidStartMicroseconds {
            ClaudeHookProcessGeneration(
                pid: previousPID,
                startSeconds: previousStartSeconds,
                startMicroseconds: previousStartMicroseconds
            )
        } else {
            nil
        }
        self.pid = pid
        if let startIdentity {
            let incomingGeneration = ClaudeHookProcessGeneration(
                pid: pid,
                startSeconds: startIdentity.seconds,
                startMicroseconds: startIdentity.microseconds
            )
            if previousGeneration != incomingGeneration {
                var priorGenerations = priorProcessGenerations ?? []
                priorGenerations.removeAll { $0 == incomingGeneration }
                if let previousGeneration {
                    priorGenerations.insert(previousGeneration, at: 0)
                }
                priorProcessGenerations = Array(priorGenerations.prefix(4))
            }
            pidStartSeconds = startIdentity.seconds
            pidStartMicroseconds = startIdentity.microseconds
        } else if previousPID != pid {
            if let previousGeneration {
                var priorGenerations = priorProcessGenerations ?? []
                priorGenerations.removeAll { $0 == previousGeneration }
                priorGenerations.insert(previousGeneration, at: 0)
                priorProcessGenerations = Array(priorGenerations.prefix(4))
            }
            pidStartSeconds = nil
            pidStartMicroseconds = nil
        }
    }

    /// Returns the persisted identity for a hook's process, including a
    /// recent prior generation retained across same-session resumes.
    func processIdentity(for pid: Int) -> AgentPIDProcessIdentity? {
        if self.pid == pid, pidStartSeconds == nil || pidStartMicroseconds == nil {
            return nil
        }
        let generations = priorProcessGenerations ?? []
        let currentGeneration: ClaudeHookProcessGeneration? = if self.pid == pid,
            let pidStartSeconds,
            let pidStartMicroseconds {
            ClaudeHookProcessGeneration(
                pid: pid,
                startSeconds: pidStartSeconds,
                startMicroseconds: pidStartMicroseconds
            )
        } else {
            nil
        }
        let generation = currentGeneration ?? generations.first { $0.pid == pid }
        guard let generation,
              generation.startSeconds != 0 || generation.startMicroseconds != 0,
              let processID = pid_t(exactly: generation.pid) else {
            return nil
        }
        return AgentPIDProcessIdentity(
            pid: processID,
            startSeconds: generation.startSeconds,
            startMicroseconds: generation.startMicroseconds
        )
    }
}

extension CMUXCLI {
    /// Asks the app whether this hook belongs to a pre-signaled hibernation
    /// generation. Unknown methods are treated as a negative answer so older
    /// app builds retain their existing cleanup behavior.
    func shouldPreserveClaudeSessionEndForHibernation(
        mappedSession: ClaudeHookSessionRecord?,
        parsedInput: ClaudeHookParsedInput,
        targetWorkspaceID: String,
        targetSurfaceID: String,
        client: SocketClient,
        environment: [String: String]
    ) -> Bool {
        guard let sessionID = parsedInput.sessionId ?? mappedSession?.sessionId,
              let rawPID = environment["CMUX_CLAUDE_PID"],
              let pid = Int(rawPID),
              let processIdentity = mappedSession?.processIdentity(for: pid) else {
            return false
        }
        let params: [String: Any] = [
            "workspace_id": targetWorkspaceID,
            "surface_id": targetSurfaceID,
            "session_id": sessionID,
            "pid": pid,
            "pid_start_seconds": processIdentity.startSeconds,
            "pid_start_microseconds": processIdentity.startMicroseconds,
        ]
        do {
            let result = try client.sendV2(
                method: "agent.hibernation.session_end",
                params: params,
                responseTimeout: 2
            )
            return result["preserve"] as? Bool == true
        } catch {
            return false
        }
    }
}
