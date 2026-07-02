import Foundation

/// Live background work an agent left running when its turn ended.
///
/// The hibernation lifecycle marks a pane `.idle` at the Stop hook, which makes it
/// eligible for reclamation (the planner SIGTERMs the scoped process group). That is
/// wrong when the agent has `run_in_background` tasks or a Monitor still running: a
/// silent background task has its own process group and produces no terminal output,
/// so it is invisible to the scrollback+PID activity fingerprint and gets killed on
/// hibernation. Claude Code reports this state to the Stop hook via `background_tasks`
/// (and scheduled `session_crons`); this value turns that payload into a single
/// `isActive` decision the Stop lane uses to record `.running` instead of `.idle`,
/// mirroring the existing antigravity `fullyIdle` gate.
///
/// Modeled as an instantiated value (it parses the payload in its initializer) and
/// lives in this package (not the CLI executable) so it is unit testable via
/// `swift test` without launching the app.
public struct AgentBackgroundWorkStatus: Equatable, Sendable {
    /// Background tasks whose status is not a known terminal state (running/pending/
    /// unknown all count — see `agentBackgroundTerminalStatuses`).
    public let runningBackgroundTaskCount: Int
    /// Scheduled cron jobs the session will wake itself for.
    public let scheduledCronCount: Int

    /// Create a status from explicit counts (used by tests and the parsing initializer).
    public init(runningBackgroundTaskCount: Int, scheduledCronCount: Int) {
        self.runningBackgroundTaskCount = runningBackgroundTaskCount
        self.scheduledCronCount = scheduledCronCount
    }

    /// Detect live background work from a Claude Code hook payload object (the full
    /// parsed JSON, e.g. `ClaudeHookParsedInput.rawObject`). Claude Code drops finished
    /// tasks from `background_tasks`, so a task present with a non-terminal status means
    /// work is still running; any `session_crons` entry means the session expects to
    /// wake itself later.
    ///
    /// Trust-boundary rule: an ABSENT field means "no background work" (older clients
    /// never send it, and they must keep hibernating), but a PRESENT field this parser
    /// cannot read — schema drift to a keyed object, an array of non-objects — fails
    /// CLOSED as one active task. This payload is the only guard between hibernation's
    /// group SIGTERM and a live background process; unreadable evidence of work must
    /// keep the pane alive (until the next parseable Stop), never authorize the kill.
    public init(hookObject object: [String: Any]?) {
        let tasks = AgentHookFieldParse(value: object?["background_tasks"])
        let crons = AgentHookFieldParse(value: object?["session_crons"])
        let running = tasks.objects.reduce(into: tasks.unreadableCount) { count, task in
            let status = ((task["status"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !agentBackgroundTerminalStatuses.contains(status) { count += 1 }
        }
        self.init(
            runningBackgroundTaskCount: running,
            scheduledCronCount: crons.objects.count + crons.unreadableCount
        )
    }

    /// Whether the pane has live background work and must stay out of hibernation.
    public var isActive: Bool {
        runningBackgroundTaskCount > 0 || scheduledCronCount > 0
    }
}

/// Statuses that mean a background task has finished and is safe to hibernate through.
/// Anything else (running, pending, queued, in_progress, or an unrecognized value) is
/// treated as live — the safe direction is to keep the pane alive rather than risk
/// killing real work.
private let agentBackgroundTerminalStatuses: Set<String> = [
    "completed", "complete", "done", "finished", "succeeded", "success",
    "failed", "failure", "error", "errored",
    "cancelled", "canceled", "killed", "terminated", "stopped",
    "exited", "timeout", "timedout",
]

/// One parsed hook array field: the readable object entries, plus how many values were
/// present but unreadable (a non-array field, or non-object array elements). Callers
/// decide what unreadable means; the background-work parser fails closed on it.
private struct AgentHookFieldParse {
    let objects: [[String: Any]]
    let unreadableCount: Int

    init(value: Any?) {
        guard let value else {
            objects = []
            unreadableCount = 0
            return
        }
        guard let array = value as? [Any] else {
            objects = []
            unreadableCount = 1
            return
        }
        let parsed = array.compactMap { $0 as? [String: Any] }
        objects = parsed
        unreadableCount = array.count - parsed.count
    }
}
