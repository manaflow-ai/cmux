import CMUXAgentLaunch
import Foundation

extension TerminalController {
    // MARK: agent.compact_resume

    /// `agent.compact_resume` {surface_id, when?, focus?}: compacts the
    /// context of the Claude Code or Codex session in a terminal pane and
    /// continues it, through the same path as the Turns popover button.
    ///
    /// Answers once the run has started; the run finishes on its own. `when`
    /// defaults to `idle` (wait for the turn to end), so an agent can run it
    /// on its own pane. Focus-neutral: nothing is selected or raised.
    nonisolated func v2AgentCompactResume(params: [String: Any]) async -> V2CallResult {
        guard let surfaceID = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "surface_id is required", data: nil)
        }
        let rawTiming = v2String(params, "when")?.lowercased() ?? AgentCompactResumeTiming.idle.rawValue
        guard let timing = AgentCompactResumeTiming(rawValue: rawTiming) else {
            return .err(code: "invalid_params", message: "when must be now or idle", data: ["when": rawTiming])
        }
        let focus = v2RawString(params, "focus")
        guard let start = await Self.startAgentCompactResume(surfaceID: surfaceID, timing: timing, focus: focus) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: ["surface_id": surfaceID.uuidString])
        }
        switch start {
        case .started(let agent):
            return .ok([
                "surface_id": surfaceID.uuidString,
                "agent": agent.statusKey,
                "when": timing.rawValue,
                "status": "started",
            ])
        case .alreadyRunning:
            return .err(
                code: "busy",
                message: String(
                    localized: "terminal.agentCompactResume.alreadyRunning",
                    defaultValue: "Compact and resume is already running in this pane."
                ),
                data: ["surface_id": surfaceID.uuidString]
            )
        case .refused(let reason):
            return .err(code: reason.socketCode, message: reason.localizedMessage, data: ["surface_id": surfaceID.uuidString])
        }
    }

    /// Main-actor half of `agent.compact_resume`: resolves the terminal pane
    /// (workspace or Dock) and starts the run. Returns `nil` when no terminal
    /// pane has that id.
    @MainActor
    static func startAgentCompactResume(
        surfaceID: UUID,
        timing: AgentCompactResumeTiming,
        focus: String?
    ) async -> AgentCompactResumeStart? {
        let panel: TerminalPanel?
        if let dock = DockSplitStore.liveStore(containingPanel: surfaceID) {
            panel = dock.panels[surfaceID] as? TerminalPanel
        } else {
            panel = AppDelegate.shared?.workspaceContainingPanel(panelId: surfaceID)?
                .workspace.terminalPanel(for: surfaceID)
        }
        guard let panel else { return nil }
        return await panel.startAgentCompactResume(timing: timing, focus: focus)
    }
}

extension AgentCompactResumeStopReason {
    /// The socket error code for a run refused at start.
    var socketCode: String {
        switch self {
        case .noAgent: "no_agent"
        case .blocked: "agent_blocked"
        case .inputNotEmpty: "input_not_empty"
        case .inputUnreadable: "input_unreadable"
        case .timedOut: "timed_out"
        case .agentExited: "agent_exited"
        }
    }
}
