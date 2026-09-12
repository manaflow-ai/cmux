#if CMUX_CLI_TESTS
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif
#endif
import Foundation

extension ClaudeHookSessionRecord {
    /// Updates the current process generation and retains a bounded history of prior generations.
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

    /// Returns the persisted identity for a hook's process, including a recent prior generation.
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
