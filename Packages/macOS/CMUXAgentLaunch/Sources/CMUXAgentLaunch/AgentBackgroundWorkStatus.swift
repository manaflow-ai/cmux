import Foundation

/// Live background work an agent left running when its turn ended.
///
/// The hibernation lifecycle marks a pane `.idle` at the Stop hook, which makes it
/// eligible for reclamation (the planner SIGTERMs the scoped process group). That is
/// wrong when the agent has `run_in_background` tasks or a Monitor still running: a
/// silent background task has its own process group and produces no terminal output,
/// so it is invisible to the scrollback+PID activity fingerprint and gets killed on
/// hibernation. Claude Code reports this state to the Stop hook via `background_tasks`
/// (and scheduled `session_crons`); this type turns that payload into a single
/// `isActive` decision the Stop lane uses to record `.running` instead of `.idle`,
/// mirroring the existing antigravity `fullyIdle` gate.
///
/// Lives in this package (not the CLI executable) so it is unit testable via
/// `swift test` without launching the app.
public struct AgentBackgroundWorkStatus: Equatable, Sendable {
    /// Background tasks whose status is not a known terminal state (running/pending/
    /// unknown all count — see `AgentBackgroundWork`).
    public let runningBackgroundTaskCount: Int
    /// Scheduled cron jobs the session will wake itself for.
    public let scheduledCronCount: Int

    public init(runningBackgroundTaskCount: Int, scheduledCronCount: Int) {
        self.runningBackgroundTaskCount = runningBackgroundTaskCount
        self.scheduledCronCount = scheduledCronCount
    }

    /// Whether the pane has live background work and must stay out of hibernation.
    public var isActive: Bool {
        runningBackgroundTaskCount > 0 || scheduledCronCount > 0
    }
}

public enum AgentBackgroundWork {
    /// Detect live background work from a Claude Code hook payload object (the full
    /// parsed JSON, e.g. `ClaudeHookParsedInput.rawObject`).
    public static func status(fromHookObject object: [String: Any]?) -> AgentBackgroundWorkStatus {
        // STUB: replaced with real detection in the following commit. Returning "no
        // background work" here reproduces the pre-fix production behavior (cmux never
        // inspects `background_tasks`), so the regression suite goes red until the real
        // parser lands.
        _ = object
        return AgentBackgroundWorkStatus(runningBackgroundTaskCount: 0, scheduledCronCount: 0)
    }
}
