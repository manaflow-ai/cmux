import Darwin
import Foundation

/// Exact Darwin process generation used to authorize anonymous agent hooks.
struct AgentHookProcessIdentity: Sendable, Equatable {
    let pid: Int
    let startSeconds: Int64
    let startMicroseconds: Int64

    init?(livePID pid: Int) {
        guard pid > 0,
              pid <= Int(Int32.max),
              let identity = AgentPIDProcessIdentity(pid: pid_t(pid)) else {
            return nil
        }
        self.pid = Int(identity.pid)
        self.startSeconds = identity.startSeconds
        self.startMicroseconds = identity.startMicroseconds
    }

    init?(record: ClaudeHookSessionRecord) {
        guard let pid = record.pid,
              let startSeconds = record.pidStartSeconds,
              let startMicroseconds = record.pidStartMicroseconds,
              pid > 0,
              pid <= Int(Int32.max),
              startSeconds >= 0,
              startMicroseconds >= 0,
              startMicroseconds < 1_000_000 else {
            return nil
        }
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    /// Orders generations by the shared kernel birth timestamp. Numeric PIDs
    /// are deliberately not a tiebreaker because equal timestamps have no
    /// trustworthy causal ordering.
    func startedBefore(_ other: Self) -> Bool {
        if startSeconds != other.startSeconds {
            return startSeconds < other.startSeconds
        }
        return startMicroseconds < other.startMicroseconds
    }

    static func processGenerationIsConfirmedDead(pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return false }
        let processID = pid_t(pid)
        if AgentPIDProcessIdentity.hasExitedWithoutReaping(pid: processID) {
            return true
        }
        if Darwin.kill(processID, 0) == 0 || errno == EPERM {
            return false
        }
        return errno == ESRCH
    }
}
