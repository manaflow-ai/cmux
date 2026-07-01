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
    /// unknown all count — see `terminalStatuses`).
    public let runningBackgroundTaskCount: Int
    /// Scheduled cron jobs the session will wake itself for.
    public let scheduledCronCount: Int

    public init(runningBackgroundTaskCount: Int, scheduledCronCount: Int) {
        self.runningBackgroundTaskCount = runningBackgroundTaskCount
        self.scheduledCronCount = scheduledCronCount
    }

    /// Detect live background work from a Claude Code hook payload object (the full
    /// parsed JSON, e.g. `ClaudeHookParsedInput.rawObject`). Claude Code drops finished
    /// tasks from `background_tasks`, so a task present with a non-terminal status means
    /// work is still running; any `session_crons` entry means the session expects to
    /// wake itself later. Wrong-typed or missing fields yield "no work" and never crash.
    public init(hookObject object: [String: Any]?) {
        let tasks = Self.arrayOfObjects(object?["background_tasks"])
        let crons = Self.arrayOfObjects(object?["session_crons"])
        let running = tasks.reduce(into: 0) { count, task in
            let status = ((task["status"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !Self.terminalStatuses.contains(status) { count += 1 }
        }
        self.init(runningBackgroundTaskCount: running, scheduledCronCount: crons.count)
    }

    /// Whether the pane has live background work and must stay out of hibernation.
    public var isActive: Bool {
        runningBackgroundTaskCount > 0 || scheduledCronCount > 0
    }

    /// Statuses that mean a background task has finished and is safe to hibernate
    /// through. Anything else (running, pending, queued, in_progress, or an
    /// unrecognized value) is treated as live — the safe direction is to keep the
    /// pane alive rather than risk killing real work.
    static let terminalStatuses: Set<String> = [
        "completed", "complete", "done", "finished", "succeeded", "success",
        "failed", "failure", "error", "errored",
        "cancelled", "canceled", "killed", "terminated", "stopped",
        "exited", "timeout", "timedout",
    ]

    private static func arrayOfObjects(_ value: Any?) -> [[String: Any]] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }
}
