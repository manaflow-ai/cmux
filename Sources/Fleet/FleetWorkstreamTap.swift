import CMUXAgentLaunch
import CmuxFleet
import Foundation

/// Bridges workstream hook events into the live Fleet engine.
@MainActor
enum FleetWorkstreamTap {
    /// Forwards one hook event when Fleet already owns the event workspace.
    static func handle(event: WorkstreamEvent) {
        guard FleetAppHost.hasLiveEngine,
              let workspaceID = event.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspaceID.isEmpty
        else { return }
        let engine = FleetAppHost.shared.engine
        guard engine.hasTask(workspaceID: workspaceID) else { return }
        engine.noteWorkstreamHook(
            workspaceID: workspaceID,
            sessionID: event.sessionId,
            pid: event.ppid.map(Int32.init),
            kind: kind(for: event.hookEventName),
            at: event.receivedAt
        )
    }

    private static func kind(for hook: WorkstreamEvent.HookEventName) -> FleetHookKind {
        switch hook {
        case .sessionStart:
            .sessionStart
        case .stop:
            .stop
        case .sessionEnd:
            .sessionEnd
        case .permissionRequest, .askUserQuestion, .exitPlanMode:
            .blockingRequest
        case .userPromptSubmit:
            .promptSubmit
        case .preToolUse, .postToolUse, .todoWrite:
            .toolUse
        case .notification:
            .notification
        case .preCompact, .postCompact, .subagentStart, .subagentStop:
            .other
        }
    }
}
