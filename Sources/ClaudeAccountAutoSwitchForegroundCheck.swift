import CmuxFoundation
import Darwin
import Foundation

/// Whether the Claude an automatic switch resumed still owns its pane's terminal, checked right
/// before cmux types `continue`.
///
/// Claude can die or be replaced without a pane-attributed `SessionEnd` reaching cmux in time,
/// and a shell prompt then reads as Claude's empty prompt. So the typing needs process evidence:
/// a Claude process the pane's hooks registered after the switch started, still the same process
/// generation, on the pane's terminal, and in that terminal's foreground process group.
struct ClaudeAccountAutoSwitchForegroundCheck {
    /// What the kernel reports about one process.
    struct ProcessFacts: Equatable, Sendable {
        /// The process's current generation.
        let identity: AgentPIDProcessIdentity
        /// Its controlling terminal device, `nil` when it has none.
        let ttyDevice: Int64?
        /// Its process group.
        let processGroup: pid_t
        /// The foreground process group of its controlling terminal.
        let terminalForegroundProcessGroup: pid_t
    }

    /// Whether one of `registered` started at or after `startedAfter`, is still that exact
    /// process, runs on `paneTTYDevice`, and is in that terminal's foreground process group.
    /// An unknown pane terminal fails the check.
    ///
    /// - Parameters:
    ///   - registered: The Claude processes recorded for the pane.
    ///   - startedAfter: When the switch started; an older process is the replaced Claude.
    ///   - paneTTYDevice: The pane terminal's PTY device.
    ///   - facts: Reads a pid's facts, `nil` once it is gone.
    static func claudeOwnsTerminal(
        registered: [AgentPIDProcessIdentity],
        startedAfter: Date,
        paneTTYDevice: Int64?,
        facts: (pid_t) -> ProcessFacts?
    ) -> Bool {
        guard let paneTTYDevice else { return false }
        let since = startedAfter.timeIntervalSince1970
        return registered.contains { identity in
            let started = Double(identity.startSeconds) + Double(identity.startMicroseconds) / 1_000_000
            guard started >= since, let current = facts(identity.pid) else { return false }
            return current.identity == identity
                && current.ttyDevice == paneTTYDevice
                && current.terminalForegroundProcessGroup > 0
                && current.processGroup == current.terminalForegroundProcessGroup
        }
    }

    /// Reads a live process's facts from the kernel.
    nonisolated static func liveFacts(pid: pid_t) -> ProcessFacts? {
        guard pid > 0, let identity = AgentPIDProcessIdentity(pid: pid) else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize) == expectedSize else { return nil }
        let device = Int64(info.e_tdev)
        return ProcessFacts(
            identity: identity,
            ttyDevice: device > 0 ? device : nil,
            processGroup: pid_t(truncatingIfNeeded: info.pbi_pgid),
            terminalForegroundProcessGroup: pid_t(truncatingIfNeeded: info.e_tpgid)
        )
    }
}
