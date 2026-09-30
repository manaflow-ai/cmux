import CmuxAgentJournal
import CMUXMobileCore
import CmuxSettings
import CmuxSidebar
import CmuxTerminal
import Foundation

/// Resumes a cmux-launched agent whose turn ended on a retryable upstream
/// failure (model at capacity, overloaded, or a dropped connection).
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
    private var autoInputSurfaces = Set<String>()

    private var isEnabled: Bool {
        AutomationCatalogSection().agentAutoResume.value(in: .standard)
    }

    func observe(_ draft: AgentJournalEventDraft) {
        guard let surfaceId = draft.surfaceId else { return }
        let action = tracker.observe(
            kind: draft.kind,
            surfaceId: surfaceId,
            isSubagent: draft.isSubagent,
            detail: draft.detail,
            sessionId: draft.sessionId
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

    func userDidInput(surfaceId: UUID) {
        let key = surfaceId.uuidString
        guard !autoInputSurfaces.contains(key) else { return }
        switch tracker.explicitInput(surfaceId: key) {
        case .none:
            break
        case .cancel(let surface):
            timers.removeValue(forKey: surface)?.cancel()
        case .schedule:
            assertionFailure("explicit input cannot schedule auto-resume")
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
        guard let input = resumeInput(for: terminal, agent: agent) else {
            tracker.abandon(surfaceId: surfaceId, token: token)
            return
        }
        autoInputSurfaces.insert(surfaceId)
        defer { autoInputSurfaces.remove(surfaceId) }
        switch input {
        case .returnKey:
            guard terminal.sendNamedKeyResult("return").accepted else {
                tracker.abandon(surfaceId: surfaceId, token: token)
                return
            }
        case .text(let text):
            guard terminal.sendTextResult(text).accepted else {
                tracker.abandon(surfaceId: surfaceId, token: token)
                return
            }
            guard terminal.sendNamedKeyResult("return").accepted else {
                tracker.abandon(surfaceId: surfaceId, token: token)
                return
            }
        }
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

    private enum ResumeInput {
        case text(String)
        case returnKey
    }

    private enum ScreenState {
        case unknown
        case emptyPrompt
        case draft
        case dialog
        case codexGoalResume
        case codexResumePicker
    }

    private func resumeInput(for terminal: TerminalPanel, agent: String) -> ResumeInput? {
        switch screenState(for: terminal.surface) {
        case .codexGoalResume where agent == "codex":
            return .text("/goal resume")
        case .codexResumePicker where agent == "codex":
            return .returnKey
        case .emptyPrompt:
            return .text(Self.resumePrompt)
        case .unknown, .draft, .dialog, .codexGoalResume, .codexResumePicker:
            return nil
        }
    }

    @MainActor
    private func screenState(for surface: TerminalSurface) -> ScreenState {
        guard let frame = surface.mobileRenderGridFrame(
            stateSeq: 0,
            includeTheme: false,
            anchor: .screen
        )?.frame else { return .unknown }
        let faintStyles = Set(frame.styles.filter(\.faint).map(\.id))
        var rows = Array(repeating: [(column: Int, text: String, faint: Bool)](), count: max(frame.rows, 0))
        for span in frame.rowSpans where span.row >= 0 && span.row < rows.count {
            rows[span.row].append((span.column, span.text, faintStyles.contains(span.styleID)))
        }
        let plainRows = rows.map { spans in
            spans.sorted { $0.column < $1.column }.reduce(into: "") { result, span in
                let padding = span.column - result.count
                if padding > 0 { result += String(repeating: " ", count: padding) }
                result += span.text
            }
        }
        let nonEmptyRows = plainRows.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if nonEmptyRows.suffix(6).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "Resume paused goal?" }) {
            return .codexResumePicker
        }
        if nonEmptyRows.last?.trimmingCharacters(in: .whitespaces) == "Goal stalled (/goal resume)" {
            return .codexGoalResume
        }
        let loweredRows = nonEmptyRows.suffix(6).map { $0.lowercased() }
        if loweredRows.contains(where: { $0.contains("esc to cancel") || $0.contains("press enter to") || $0.contains("enter to confirm") || $0.contains("enter to select") }) {
            return .dialog
        }
        let promptPrefixes = ["› ", "❯ ", "❯\u{00A0}", "> "]
        let barePromptMarkers = ["❯", ">"]
        guard let lastNonEmptyIndex = plainRows.lastIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }),
        let promptIndex = plainRows.lastIndex(where: { row in
            let trimmed = row.drop(while: { $0 == " " || $0 == "│" })
            return promptPrefixes.contains(where: trimmed.hasPrefix)
                || barePromptMarkers.contains(String(trimmed))
        }),
        promptIndex == lastNonEmptyIndex else { return .unknown }
        var typed = ""
        for index in promptIndex..<rows.count {
            let spans = rows[index].sorted { $0.column < $1.column }
            for span in spans where !span.faint {
                typed += span.text
            }
            if index == promptIndex {
                for prefix in promptPrefixes where typed.hasPrefix(prefix) {
                    typed.removeFirst(prefix.count)
                    break
                }
                if barePromptMarkers.contains(typed) {
                    typed.removeAll()
                }
            }
        }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyPrompt : .draft
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
