import CmuxFoundation
import Darwin

/// Decides whether persisted Codex turn state can still belong to a live process.
///
/// A dead PID or a mismatched recorded PID generation is safe to reclaim. A
/// missing PID or generation remains live-owner uncertainty and keeps the
/// stale turn guard conservative.
enum CodexSessionTurnOwnerAdmission {
    static func recordedTurnOwnerMayStillBeAlive(
        _ record: ClaudeHookSessionRecord
    ) -> Bool {
        guard let pid = record.pid,
              pid > 0,
              pid <= Int(Int32.max) else {
            return true
        }
        guard Darwin.kill(pid_t(pid), 0) == 0 || errno == EPERM else {
            return false
        }
        guard let startSeconds = record.pidStartSeconds,
              let startMicroseconds = record.pidStartMicroseconds else {
            return true
        }
        guard let identity = AgentPIDProcessIdentity(pid: pid_t(pid)) else {
            return true
        }
        return identity.startSeconds == startSeconds
            && identity.startMicroseconds == startMicroseconds
    }
}
