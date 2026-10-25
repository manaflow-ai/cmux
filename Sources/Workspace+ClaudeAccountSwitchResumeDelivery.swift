import CmuxTerminal
import CmuxTerminalCore
import CmuxWorkspaces
import Foundation
import Observation

extension Workspace {
    /// How waiting for a respawned shell's first prompt ended.
    enum ClaudeAccountSwitchShellReadiness: Equatable {
        /// The shell in the respawned panel reported its prompt.
        case prompt
        /// The pane was closed, moved or respawned again before that shell reported a prompt.
        case replaced
        /// No prompt report arrived in time: rc files were still running, or the shell has no
        /// cmux prompt reporting (integration off, or an unsupported shell).
        case timedOut
    }

    /// How delivering a switch's resume input ended.
    enum ClaudeAccountSwitchResumeDelivery: Equatable {
        /// The input reached the respawned shell.
        case typed
        /// The pane was closed, moved or respawned again first; there is no pane to type into.
        case paneReplaced
        /// The shell reported no prompt in time, or the terminal refused the input.
        case notTyped
    }

    /// Upper bound on waiting for the respawned shell to reach its prompt.
    private static let claudeAccountSwitchPromptTimeout: Duration = .seconds(15)

    /// Types `input` into the respawned `panel` once its shell reports a prompt.
    ///
    /// Typing earlier would land while rc files still run in canonical mode, where an rc-time
    /// stdin reader can eat the command (#5473). Nothing is typed when the pane goes away or no
    /// prompt arrives in time.
    ///
    /// - Parameter requiresUntouchedShellLine: For the unattended automatic switch: type nothing
    ///   when the respawned shell's line may already hold other input (see
    ///   ``ClaudeAccountSwitchShellLine``). A manual switch was asked for by the person at the
    ///   pane, so it types regardless.
    @MainActor
    func deliverClaudeAccountSwitchResumeInput(
        _ input: String,
        to panel: TerminalPanel,
        panelId: UUID,
        requiresUntouchedShellLine: Bool = false
    ) async -> ClaudeAccountSwitchResumeDelivery {
        switch await waitForClaudeAccountSwitchShellPrompt(
            panelId: panelId,
            panel: panel,
            timeout: Self.claudeAccountSwitchPromptTimeout
        ) {
        case .replaced:
            return .paneReplaced
        case .timedOut:
            return .notTyped
        case .prompt:
            if requiresUntouchedShellLine, !ClaudeAccountSwitchShellLine.acceptsResumeInput(
                receivedInputSinceRespawn: panel.hasReceivedExplicitInput,
                screen: AgentAutoResumeCoordinator.shared.screenState(for: panel.surface)
            ) {
                return .notTyped
            }
            return typeClaudeAccountSwitchResumeInput(input, into: panel, panelId: panelId) ? .typed : .notTyped
        }
    }

    /// Types a switch's resume input into `panel` now, without waiting for a prompt. Nothing is
    /// typed when the pane no longer holds `panel`: it was closed, moved or respawned again.
    ///
    /// - Returns: Whether the input reached the terminal.
    @MainActor
    func typeClaudeAccountSwitchResumeInput(
        _ input: String,
        into panel: TerminalPanel,
        panelId: UUID
    ) -> Bool {
        guard terminalPanel(for: panelId) === panel else { return false }
        return panel.sendInputResult(input).accepted
    }

    /// Waits until the shell in `panel` reports its prompt, the pane loses `panel`, or
    /// `timeout` passes.
    ///
    /// A respawn clears the pane's `panelShellActivityStates` entry, and a report is admitted
    /// only from the current terminal generation, so `.promptIdle` there means this shell got
    /// through its rc files. The panel's own activity model is not used: a blank panel starts
    /// at an optimistic `.promptIdle`. Every change to the shell states or the pane's panels
    /// wakes the wait, so a closed or replaced pane ends it at once.
    @MainActor
    func waitForClaudeAccountSwitchShellPrompt(
        panelId: UUID,
        panel: TerminalPanel,
        timeout: Duration
    ) async -> ClaudeAccountSwitchShellReadiness {
        let (changes, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        // Genuine deadline: a shell that never reports a prompt must not hold the switch.
        let deadline = Task {
            try? await ContinuousClock().sleep(for: timeout)
            continuation.finish()
        }
        defer {
            deadline.cancel()
            continuation.finish()
        }
        if let readiness = observeClaudeAccountSwitchShellReadiness(
            panelId: panelId,
            panel: panel,
            onChange: continuation
        ) {
            return readiness
        }
        for await _ in changes {
            if let readiness = observeClaudeAccountSwitchShellReadiness(
                panelId: panelId,
                panel: panel,
                onChange: continuation
            ) {
                return readiness
            }
        }
        return claudeAccountSwitchShellReadiness(panelId: panelId, panel: panel) ?? .timedOut
    }

    /// Reads the readiness and arms a one-shot observation of what it read.
    @MainActor
    private func observeClaudeAccountSwitchShellReadiness(
        panelId: UUID,
        panel: TerminalPanel,
        onChange continuation: AsyncStream<Void>.Continuation
    ) -> ClaudeAccountSwitchShellReadiness? {
        withObservationTracking {
            claudeAccountSwitchShellReadiness(panelId: panelId, panel: panel)
        } onChange: {
            continuation.yield()
        }
    }

    /// `nil` while the pane still holds `panel` and its shell has not reported a prompt.
    @MainActor
    private func claudeAccountSwitchShellReadiness(
        panelId: UUID,
        panel: TerminalPanel
    ) -> ClaudeAccountSwitchShellReadiness? {
        guard terminalPanel(for: panelId) === panel else { return .replaced }
        return panelShellActivityStates[panelId] == .promptIdle ? .prompt : nil
    }
}
