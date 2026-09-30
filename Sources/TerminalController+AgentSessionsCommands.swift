import CmuxMobileHost
import Foundation

/// Socket v2 surface for the live agent-session registry.
extension TerminalController {
    /// `agent.sessions.list` — every chat-capable agent session the Mac
    /// currently knows about, in attention order, across all workspaces.
    ///
    /// This reads the live registry (`AgentChatSessionRegistry`, fed by agent
    /// hooks), not the saved hook records on disk that `cmux sessions list`
    /// walks. The difference is the point: only the registry carries the
    /// current `state`, when that state began, and the conversation title, so
    /// only the registry can answer "which agent is waiting on me right now".
    ///
    /// Deliberately unscoped. The registry can filter by its stored
    /// `workspaceID`, but that field goes stale: cmux re-mints workspace ids on
    /// every relaunch while surface bindings survive, so a workspace filter
    /// keyed on it silently drops sessions created before the last relaunch.
    /// `mobile.chat.sessions` solves that by resolving the workspace's live
    /// surface ids first; until this verb does the same, it returns everything
    /// and lets the caller filter on the `workspace_id` it can see. A
    /// cross-workspace list is what this verb is for in any case.
    ///
    /// Not relay-exported. `RemoteRelayCommandPolicy` denies by default and
    /// this method is not on its allowlist, which is correct: the reply spans
    /// every workspace on the Mac and carries conversation titles, working
    /// directories, transcript paths and pids. That is local state a remote
    /// session has no business reading, so the method stays local-only.
    func v2AgentSessionsList() -> V2CallResult {
        guard let service = agentChatTranscriptService else {
            return .err(code: "unavailable", message: Self.chatServiceUnavailableErrorMessage, data: nil)
        }
        // `AgentSessionListPayload.list` applies the attention ordering, so
        // every client of this verb shares one triage order.
        let records = service.sessionRecords(workspaceID: nil).map { record -> AgentChatSessionRecord in
            guard record.lastOutput == nil,
                  let rawSurfaceID = record.surfaceID,
                  let surfaceID = UUID(uuidString: rawSurfaceID),
                  let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID),
                  let visibleText = surface.visibleText(),
                  let preview = AgentSessionOutputPreview.tail(visibleText, lines: 3) else {
                return record
            }
            var copy = record
            copy.lastOutput = preview
            return copy
        }
        return .ok(AgentSessionListPayload().list(
            records: records,
            now: Date()
        ))
    }
}
