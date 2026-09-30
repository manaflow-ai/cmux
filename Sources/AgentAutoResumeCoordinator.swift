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
            let sessionId = tracker.pendingSessionId(surfaceId: surface, token: token)
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
                self?.fire(
                    surfaceId: surface,
                    token: token,
                    attempt: attempt,
                    workspaceHint: workspaceHint,
                    agent: agent,
                    sessionId: sessionId
                )
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

    private func fire(
        surfaceId: String,
        token: UInt64,
        attempt: Int,
        workspaceHint: String?,
        agent: String,
        sessionId: String?
    ) {
        timers[surfaceId] = nil
        guard tracker.isPending(surfaceId: surfaceId, token: token) else { return }
        guard isEnabled, let panelId = UUID(uuidString: surfaceId),
              let target = resumeTarget(
                  panelId: panelId,
                  workspaceHint: workspaceHint.flatMap(UUID.init(uuidString:))
              ),
              target.matchesManagedSession(sessionId, agent: agent) else {
            tracker.abandon(surfaceId: surfaceId, token: token)
            return
        }
        let terminal = target.terminal
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
        let statusEntry = SidebarStatusEntry(
            key: Self.statusKey,
            value: String.localizedStringWithFormat(
                String(localized: "agent.autoResume.status", defaultValue: "Auto-resumed ×%lld"),
                total
            ),
            icon: "arrow.clockwise",
            color: "#4C8DFF"
        )
        target.setStatusEntry(statusEntry, key: Self.statusKey)
        CmuxEventBus.shared.publish(
            name: "agent.auto_resume.sent",
            category: "agent",
            source: "auto_resume",
            workspaceId: target.workspaceId.uuidString,
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

    enum ScreenState: Equatable {
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
        return Self.screenState(in: frame)
    }

    static func screenState(in frame: MobileTerminalRenderGridFrame) -> ScreenState {
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
        let nonEmptyRows = plainRows.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let pickerRows = [
            "› 1. Resume goal   Mark it active and continue when idle",
            "2. Leave paused  Keep it paused; use /goal resume later",
            "enter select · esc back"
        ]
        if nonEmptyRows.suffix(10).contains("Resume paused goal?"),
           Array(nonEmptyRows.suffix(3)) == pickerRows {
            return .codexResumePicker
        }
        let loweredRows = nonEmptyRows.suffix(6).map { $0.lowercased() }
        if loweredRows.contains(where: { $0.contains("esc to cancel") || $0.contains("press enter to") || $0.contains("enter to confirm") || $0.contains("enter to select") || $0.contains("enter select") || $0.contains("esc back") }) {
            return .dialog
        }
        let promptPrefixes = ["› ", "❯ ", "❯\u{00A0}", "> "]
        guard let cursor = frame.cursor,
              cursor.visible,
              plainRows.indices.contains(cursor.row) else { return .unknown }
        let promptIndex = cursor.row
        let trimmedPrompt = plainRows[promptIndex].drop(while: { $0 == " " || $0 == "│" })
        guard promptPrefixes.contains(where: trimmedPrompt.hasPrefix)
            || trimmedPrompt == "›" || trimmedPrompt == "❯" else { return .unknown }
        var typed = rows[promptIndex]
            .sorted { $0.column < $1.column }
            .filter { !$0.faint }
            .reduce(into: "") { result, span in
                let padding = span.column - result.count
                if padding > 0 { result += String(repeating: " ", count: padding) }
                result += span.text
            }
        typed = String(typed.drop(while: { $0 == " " || $0 == "│" }))
        if let prefix = promptPrefixes.first(where: typed.hasPrefix) {
            typed.removeFirst(prefix.count)
        } else if typed == "›" || typed == "❯" {
            typed = ""
        }
        guard typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .draft }
        let stalledFooter = nonEmptyRows.last?.hasSuffix("Goal stalled (/goal resume)") == true
        for index in (promptIndex + 1)..<rows.count {
            let plain = plainRows[index].trimmingCharacters(in: .whitespaces)
            if plain.isEmpty || plain.allSatisfy({ "─│╭╮╰╯".contains($0) || $0.isWhitespace }) {
                break
            }
            let typedRow = rows[index].filter { !$0.faint }.map(\.text).joined()
                .trimmingCharacters(in: .whitespaces)
            guard !typedRow.isEmpty else { continue }
            let lowered = typedRow.lowercased()
            let contextParts = lowered.components(separatedBy: " · ctx ")
            let isClaudeModelStatus = contextParts.count == 2
                && ["sonnet ", "opus ", "haiku "].contains(where: contextParts[0].hasPrefix)
                && contextParts[1].hasSuffix("%")
                && Int(contextParts[1].dropLast()) != nil
            let isClaudeModeStatus = lowered.hasPrefix("⏵⏵ auto mode on (shift+tab to cycle)")
            let codexStatusParts = lowered.components(separatedBy: " · ")
            let codexPathField: Bool
            if codexStatusParts.count == 2 {
                codexPathField = codexStatusParts[1].hasPrefix("/")
            } else {
                let contextField = codexStatusParts[1]
                let percentageContext = contextField.hasSuffix("% context left")
                codexPathField = codexStatusParts.count >= 3
                    && (contextField.hasPrefix("context ") || percentageContext)
                    && codexStatusParts[2].hasPrefix("/")
            }
            let isCodexModelStatus = codexStatusParts.first?.hasPrefix("gpt-") == true
                && codexStatusParts.first?.contains(" ") == true
                && codexPathField
            let isStalledFooter = lowered.hasSuffix("goal stalled (/goal resume)")
            let isStatusRow = isClaudeModelStatus || isClaudeModeStatus || isCodexModelStatus || isStalledFooter
            if !isStatusRow {
                return .draft
            }
        }
        return stalledFooter ? .codexGoalResume : .emptyPrompt
    }

    private func clearMarker(surfaceId: String, workspaceHint: String?) {
        guard let panelId = UUID(uuidString: surfaceId),
              let target = resumeTarget(
                  panelId: panelId,
                  workspaceHint: workspaceHint.flatMap(UUID.init(uuidString:))
              ) else { return }
        target.clearStatusEntry(key: Self.statusKey)
    }

    @MainActor
    private enum ResumeTarget {
        case workspace(Workspace, TerminalPanel)
        case dock(DockSplitStore, TerminalPanel)

        var terminal: TerminalPanel {
            switch self {
            case .workspace(_, let terminal), .dock(_, let terminal): terminal
            }
        }

        var workspaceId: UUID {
            switch self {
            case .workspace(let workspace, _): workspace.id
            case .dock(let dock, _): dock.workspaceId
            }
        }

        @MainActor
        func matchesManagedSession(_ sessionId: String?, agent: String) -> Bool {
            let binding: SurfaceResumeBindingSnapshot?
            let currentSessionId: String?
            switch self {
            case .workspace(let workspace, let terminal):
                binding = workspace.surfaceResumeBinding(panelId: terminal.id)
                currentSessionId = binding?.checkpointId
                    ?? workspace.restoredAgentSnapshotsByPanelId[terminal.id]?.sessionId
            case .dock(let dock, let terminal):
                binding = dock.managedAgentResumeBinding(panelId: terminal.id)
                    ?? dock.surfaceResumeBinding(panelId: terminal.id)
                currentSessionId = binding?.checkpointId
                    ?? binding?.managedRestorableAgentSnapshot(replacing: nil)?.sessionId
            }
            guard let binding,
                  binding.isAgentHookBinding,
                  binding.kind == nil
                      || binding.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == agent.lowercased()
            else { return false }
            guard let sessionId, !sessionId.isEmpty else { return currentSessionId == nil }
            guard let currentSessionId else { return false }
            return currentSessionId == sessionId
        }

        func setStatusEntry(_ entry: SidebarStatusEntry, key: String) {
            switch self {
            case .workspace(let workspace, let terminal):
                workspace.setStatusEntry(entry, key: key, panelId: terminal.id)
            case .dock(let dock, let terminal):
                dock.setAgentRuntimeStatusEntry(entry, key: key, panelId: terminal.id)
            }
        }

        func clearStatusEntry(key: String) {
            switch self {
            case .workspace(let workspace, let terminal):
                workspace.clearStatusEntry(key: key, panelId: terminal.id)
            case .dock(let dock, let terminal):
                dock.clearAgentRuntimeStatusEntry(key: key, panelId: terminal.id)
            }
        }
    }

    private func resumeTarget(panelId: UUID, workspaceHint: UUID?) -> ResumeTarget? {
        if let dock = DockSplitStore.liveStore(containingPanel: panelId),
           let terminal = dock.panels[panelId] as? TerminalPanel {
            return .dock(dock, terminal)
        }
        guard let located = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelId,
            preferredWorkspaceId: workspaceHint
        ),
        let terminal = located.workspace.terminalPanel(for: panelId) else {
            return nil
        }
        return .workspace(located.workspace, terminal)
    }
}
