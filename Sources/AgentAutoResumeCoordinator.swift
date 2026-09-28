import CmuxAgentJournal
import CmuxSettings
import CmuxSidebar
import Foundation

/// Sends `continue` to a cmux-launched agent whose turn ended on a retryable
/// upstream failure (model at capacity, overloaded, a dropped connection).
///
/// The decision lives in ``AgentAutoResumeTracker``; this type owns the
/// timers and the one delivery path. It observes live journal events only
/// (never a replay), so restoring history can not type into a terminal. A
/// resume fires only while nothing else happened on the surface since the
/// error: a prompt, a permission request, or a new turn cancels it.
@MainActor
final class AgentAutoResumeCoordinator {
    static let shared = AgentAutoResumeCoordinator()

    /// Sidebar status key of the "Auto-resumed ×N" marker.
    static let statusKey = "agent_auto_resume"
    static let resumePrompt = "continue"

    private var tracker = AgentAutoResumeTracker()
    private var timers: [String: Task<Void, Never>] = [:]

    private var isEnabled: Bool {
        AutomationCatalogSection().agentAutoResume.value(in: .standard)
    }

    func observe(_ draft: AgentJournalEventDraft) {
        guard let surfaceId = draft.surfaceId else { return }
        let action = tracker.observe(
            kind: draft.kind,
            surfaceId: surfaceId,
            isSubagent: draft.isSubagent,
            detail: draft.detail
        )
        if draft.kind == .sessionEnded {
            clearMarker(surfaceId: surfaceId, workspaceHint: draft.workspaceId)
        }
        switch action {
        case .none:
            return
        case .cancel(let surface):
            timers.removeValue(forKey: surface)?.cancel()
#if DEBUG
            cmuxDebugLog("agentAutoResume.cancel surface=\(surface.prefix(8)) kind=\(draft.kind.rawValue)")
#endif
        case let .schedule(surface, attempt, delay, token):
            guard isEnabled else {
                tracker.abandon(surfaceId: surface, token: token)
                return
            }
            timers.removeValue(forKey: surface)?.cancel()
            let workspaceHint = draft.workspaceId
            let agent = draft.source
            CmuxEventBus.shared.publish(
                name: "agent.auto_resume.scheduled",
                category: "agent",
                source: "auto_resume",
                workspaceId: workspaceHint,
                surfaceId: surface,
                payload: ["agent": agent, "attempt": attempt, "delay_ms": Int(delay.components.seconds * 1_000)]
            )
#if DEBUG
            cmuxDebugLog("agentAutoResume.schedule surface=\(surface.prefix(8)) agent=\(agent) attempt=\(attempt)")
#endif
            timers[surface] = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.fire(surfaceId: surface, token: token, attempt: attempt, workspaceHint: workspaceHint, agent: agent)
            }
        }
    }

    private func fire(surfaceId: String, token: UInt64, attempt: Int, workspaceHint: String?, agent: String) {
        timers[surfaceId] = nil
        guard tracker.isPending(surfaceId: surfaceId, token: token) else { return }
        guard isEnabled,
              let panelId = UUID(uuidString: surfaceId),
              let located = AppDelegate.shared?.workspaceContainingPanel(
                  panelId: panelId,
                  preferredWorkspaceId: workspaceHint.flatMap(UUID.init(uuidString:))
              ),
              let terminal = located.workspace.terminalPanel(for: panelId) else {
            tracker.abandon(surfaceId: surfaceId, token: token)
            return
        }
        // Same submission as a mobile paste: the text, then the agent's
        // submit key for single-line input.
        guard terminal.sendTextResult(Self.resumePrompt).accepted else {
            tracker.abandon(surfaceId: surfaceId, token: token)
            return
        }
        _ = terminal.sendNamedKeyResult("return")
        guard let total = tracker.resumeSent(surfaceId: surfaceId, token: token) else { return }
        located.workspace.statusEntries[Self.statusKey] = SidebarStatusEntry(
            key: Self.statusKey,
            value: String.localizedStringWithFormat(
                String(localized: "agent.autoResume.status", defaultValue: "Auto-resumed ×%lld"),
                total
            ),
            icon: "arrow.clockwise",
            color: "#4C8DFF"
        )
        CmuxEventBus.shared.publish(
            name: "agent.auto_resume.sent",
            category: "agent",
            source: "auto_resume",
            workspaceId: located.workspace.id.uuidString,
            surfaceId: surfaceId,
            payload: ["agent": agent, "attempt": attempt, "total": total]
        )
#if DEBUG
        cmuxDebugLog("agentAutoResume.sent surface=\(surfaceId.prefix(8)) agent=\(agent) attempt=\(attempt) total=\(total)")
#endif
    }

    private func clearMarker(surfaceId: String, workspaceHint: String?) {
        guard let panelId = UUID(uuidString: surfaceId),
              let located = AppDelegate.shared?.workspaceContainingPanel(
                  panelId: panelId,
                  preferredWorkspaceId: workspaceHint.flatMap(UUID.init(uuidString:))
              ) else { return }
        located.workspace.statusEntries.removeValue(forKey: Self.statusKey)
    }
}
