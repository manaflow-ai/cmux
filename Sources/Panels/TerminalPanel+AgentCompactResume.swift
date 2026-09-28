import CMUXAgentLaunch
import Foundation

extension TerminalPanel {
    /// Compacts the pane agent's context and continues where it left off:
    /// the one path behind the Turns popover button and the
    /// `agent.compact_resume` socket verb.
    ///
    /// Builds a focus note from the session's last prompts (or `focus`),
    /// then hands the sequence to an ``AgentCompactResumeRun``, which
    /// interrupts first only when `timing` is `.now`, types `/compact` once
    /// the agent is idle with an empty input line, and sends the continue
    /// prompt after the agent's PostCompact hook.
    ///
    /// - Parameters:
    ///   - timing: Whether a running turn is interrupted or waited out.
    ///   - focus: Replaces the generated focus note when non-empty.
    ///   - readInput: Reads the agent's input line; defaults to the pane's
    ///     styled screen. Tests supply their own.
    ///   - settleInterval: The wait after an interrupt, shortened by tests.
    @discardableResult
    func startAgentCompactResume(
        timing: AgentCompactResumeTiming,
        focus: String? = nil,
        readInput: (@MainActor (AgentCompactResumeDialect) -> AgentPromptInputState)? = nil,
        settleInterval: Duration = AgentCompactResumeFlow.settleInterval
    ) async -> AgentCompactResumeStart {
        if let refusal = agentCompactResumePrecheck() { return refusal }
        guard let agent = AgentTurnInterruptTarget.present(statusKeyedStates: containerAgentLifecycleStates) else {
            return .refused(.noAgent)
        }
        let surfaceID = id
        let kind: RestorableAgentKind = agent == .claudeCode ? .claude : .codex
        let context = await Task.detached(priority: .userInitiated) { () -> (String?, [String]) in
            let session = AgentPaneSessionLocator(agent: kind).session(surfaceID: surfaceID)
            let prompts = session?.transcriptPath.map {
                AgentRecentPromptReader(agent: agent).prompts(transcriptURL: URL(fileURLWithPath: $0))
            } ?? []
            return (session?.sessionID, prompts)
        }.value

        // The pane may have changed while the transcript was read.
        if let refusal = agentCompactResumePrecheck() { return refusal }
        guard AgentTurnInterruptTarget.present(statusKeyedStates: containerAgentLifecycleStates) == agent else {
            return .refused(.noAgent)
        }
        let dialect = agent.compactResumeDialect
        let note = AgentCompactResumeFocusNote(recentPrompts: context.1, customFocus: focus)
        let flow = AgentCompactResumeFlow(
            timing: timing,
            compactCommand: dialect.compactCommand(focus: note),
            resumePrompt: dialect.resumePrompt(focus: note)
        )
        let readInput: @MainActor (AgentCompactResumeDialect) -> AgentPromptInputState = readInput ?? { [weak self] dialect in
            self?.readAgentPromptInput(dialect: dialect) ?? .unknown
        }
        let run = AgentCompactResumeRun(
            agent: agent,
            surfaceID: surfaceID,
            sessionID: context.0,
            flow: flow,
            pane: .init(
                lifecycle: { [weak self] in self?.agentCompactResumeLifecycle(agent) ?? .absent },
                readInput: { readInput(dialect) },
                interrupt: { [weak self] in self?.interruptAgentTurn(agent) },
                submit: { [weak self] text in self?.submitAgentPrompt(text) }
            ),
            settleInterval: settleInterval,
            onPhaseChange: { [weak self] phase in self?.agentCompactResumePhaseChanged(phase) }
        )
        agentCompactResumeRun = run
        run.start()
        if case .finished(.stopped(let reason)) = run.flow.phase {
            return .refused(reason)
        }
        return .started(agent)
    }

    /// The fast refusals, checked before and after the transcript read.
    private func agentCompactResumePrecheck() -> AgentCompactResumeStart? {
        if let run = agentCompactResumeRun, !run.isFinished { return .alreadyRunning }
        let states = containerAgentLifecycleStates
        guard let agent = AgentTurnInterruptTarget.present(statusKeyedStates: states) else {
            return .refused(.noAgent)
        }
        if agentCompactResumeLifecycle(agent) == .blocked { return .refused(.blocked) }
        return nil
    }

    func agentCompactResumeLifecycle(_ agent: AgentTurnInterruptTarget) -> AgentCompactResumeLifecycle {
        switch containerAgentLifecycleStates[agent.statusKey] {
        case nil: .absent
        case .running: .running
        case .idle: .idle
        case .needsInput, .unknown: .blocked
        }
    }

    /// Types a single-line prompt into the agent and submits it, the way
    /// `mobile.chat.send` does: a paste, then Return.
    private func submitAgentPrompt(_ text: String) {
        guard sendTextResult(text).accepted else { return }
        _ = sendNamedKeyResult(TextBoxTerminalKey.returnKey.rawValue)
    }

    /// Classifies the agent's input line from the active screen's styled
    /// text. Unreadable screens are `.unknown`, which stops the run.
    func readAgentPromptInput(dialect: AgentCompactResumeDialect) -> AgentPromptInputState {
        guard let screen = TerminalController.shared.readTerminalTextFromVTExportForSnapshot(
            terminalPanel: self,
            bindingAction: "write_active_file:copy,vt",
            lineLimit: nil,
            normalizeLineEndings: false
        ) else { return .unknown }
        return AgentPromptInputReader(dialect: dialect).state(screen: screen)
    }

    private func agentCompactResumePhaseChanged(_ phase: AgentCompactResumeFlow.Phase) {
        let view = hostedView.agentTurnControlView
        switch phase {
        case .waitingForIdle, .settling:
            view.setCompactResumeStatus(String(
                localized: "terminal.agentCompactResume.status.waiting",
                defaultValue: "Waiting to compact…"
            ), isError: false)
        case .compacting:
            view.setCompactResumeStatus(String(
                localized: "terminal.agentCompactResume.status.compacting",
                defaultValue: "Compacting…"
            ), isError: false)
        case .finished(let outcome):
            agentCompactResumeRun = nil
            switch outcome {
            case .resumed:
                view.setCompactResumeStatus(nil, isError: false)
            case .stopped(let reason):
                view.setCompactResumeStatus(reason.localizedMessage, isError: true)
            }
        }
    }
}

extension AgentTurnInterruptTarget {
    var compactResumeDialect: AgentCompactResumeDialect {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        }
    }
}

extension AgentCompactResumeStopReason {
    /// What the user reads when a run stops without resuming.
    var localizedMessage: String {
        switch self {
        case .noAgent:
            String(localized: "terminal.agentCompactResume.stopped.noAgent",
                   defaultValue: "No Claude Code or Codex session in this pane.")
        case .blocked:
            String(localized: "terminal.agentCompactResume.stopped.blocked",
                   defaultValue: "The agent is waiting on a question. Answer it, then try again.")
        case .inputNotEmpty:
            String(localized: "terminal.agentCompactResume.stopped.inputNotEmpty",
                   defaultValue: "The agent's input has text in it. Send or clear it, then try again.")
        case .inputUnreadable:
            String(localized: "terminal.agentCompactResume.stopped.inputUnreadable",
                   defaultValue: "Couldn't read the agent's input, so nothing was typed.")
        case .timedOut:
            String(localized: "terminal.agentCompactResume.stopped.timedOut",
                   defaultValue: "Compact and resume timed out. Nothing more was typed.")
        case .agentExited:
            String(localized: "terminal.agentCompactResume.stopped.agentExited",
                   defaultValue: "The agent session ended.")
        }
    }
}
