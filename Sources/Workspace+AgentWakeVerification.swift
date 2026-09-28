import CmuxSidebar
import Foundation

/// Checks that an agent woken from hibernation actually came back.
///
/// A wake types the agent's resume command into a fresh shell. If that
/// command fails (launcher missing from PATH, session gone), the pane would
/// otherwise sit at a shell prompt with no sign that anything went wrong.
/// The check succeeds when an agent hook reports a PID or lifecycle state for
/// the pane. It fails when the resume command returns to the prompt first, or
/// when nothing reports in before the deadline and no live agent process is
/// found. A failure shows a banner on the pane, a sidebar row and one feed
/// entry.
extension Workspace {
    static let agentWakeFailedStatusKey = "agent.wakeFailed"
    static let agentWakeVerificationSeconds: TimeInterval = 90

    /// Starts (or restarts) the wake check for `panelId`.
    func beginAgentWakeVerification(
        panelId: UUID,
        agent: SessionRestorableAgentSnapshot,
        deadlineSeconds: TimeInterval = Workspace.agentWakeVerificationSeconds
    ) {
        guard let terminalPanel = terminalPanel(for: panelId) else { return }
        agentWakeVerificationsByPanelId[panelId]?.deadlineTask?.cancel()
        let token = UUID()
        let deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(deadlineSeconds))
            guard !Task.isCancelled else { return }
            self?.resolveAgentWakeVerificationDeadline(panelId: panelId, token: token)
        }
        let initialState = (agentWakeVerificationsByPanelId[panelId]?.state ?? .pending)
            .applying(.started)
        agentWakeVerificationsByPanelId[panelId] = AgentWakeVerification(
            token: token,
            agent: agent,
            startedAt: Date(),
            commandText: Self.agentWakeCommandText(for: agent),
            state: initialState,
            deadlineTask: deadlineTask
        )
        clearAgentWakeFailurePresentation(on: terminalPanel)
        refreshAgentWakeFailureStatusEntry()
    }

    /// An agent hook reported a PID or a non-manual lifecycle state for the pane.
    func noteAgentWakeAgentReported(panelId: UUID) {
        applyAgentWakeVerificationEvent(.agentReported, panelId: panelId)
    }

    /// The restored resume command returned to the shell prompt.
    func noteAgentWakeCommandEnded(panelId: UUID) {
        applyAgentWakeVerificationEvent(.commandEnded, panelId: panelId)
    }

    /// Fails a pending wake check directly. The normal paths are the
    /// command-ended signal and the deadline; this entry point keeps the
    /// failure presentation testable without driving a real resume.
    func failAgentWakeVerification(panelId: UUID, reason: AgentWakeFailureReason) {
        guard agentWakeVerificationsByPanelId[panelId]?.state == .pending else { return }
        applyAgentWakeVerificationState(.failed(reason), panelId: panelId)
    }

    /// Closes the failure banner and forgets the check.
    func dismissAgentWakeFailure(panelId: UUID) {
        discardAgentWakeVerification(panelId: panelId)
    }

    /// Types the resume command again and restarts the check.
    func retryAgentWake(panelId: UUID) {
        guard let verification = agentWakeVerificationsByPanelId[panelId],
              verification.state.failureReason != nil,
              let terminalPanel = terminalPanel(for: panelId),
              !terminalPanel.isAgentHibernated,
              let startupInput = verification.agent.resumeStartupInput() else {
            return
        }
        if restoredAgentSnapshotsByPanelId[panelId] != nil {
            // Same state a wake leaves behind, so the shell callbacks can
            // tell when this retry's command starts and ends.
            restoredAgentLifecycle.setResumeState(.awaitingAutoResumeCommand, panelId: panelId)
        }
        beginAgentWakeVerification(panelId: panelId, agent: verification.agent)
        sendInputWhenReady(startupInput, to: terminalPanel)
    }

    /// Drops any check and failure for the pane, for example when it closes
    /// or hibernates again. Pass `panel` when it has already left `panels`.
    func discardAgentWakeVerification(panelId: UUID, panel: TerminalPanel? = nil) {
        let removed = agentWakeVerificationsByPanelId.removeValue(forKey: panelId)
        removed?.deadlineTask?.cancel()
        if let terminalPanel = panel ?? terminalPanel(for: panelId) {
            clearAgentWakeFailurePresentation(on: terminalPanel)
        }
        if removed != nil {
            refreshAgentWakeFailureStatusEntry()
        }
    }

    static func agentWakeCommandText(for agent: SessionRestorableAgentSnapshot) -> String {
        if let command = agent.resumeCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            return command
        }
        return agent.resumeStartupInput()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func resolveAgentWakeVerificationDeadline(panelId: UUID, token: UUID) {
        guard let verification = agentWakeVerificationsByPanelId[panelId],
              verification.token == token,
              verification.state == .pending else {
            return
        }
        let hasLiveProcess = restoredAgentHasLiveProcess(verification.agent, panelId: panelId)
        applyAgentWakeVerificationEvent(.deadline(hasLiveProcess: hasLiveProcess), panelId: panelId)
    }

    private func applyAgentWakeVerificationEvent(
        _ event: AgentWakeVerificationState.Event,
        panelId: UUID
    ) {
        guard let verification = agentWakeVerificationsByPanelId[panelId] else { return }
        applyAgentWakeVerificationState(verification.state.applying(event), panelId: panelId)
    }

    private func applyAgentWakeVerificationState(
        _ nextState: AgentWakeVerificationState,
        panelId: UUID
    ) {
        guard var verification = agentWakeVerificationsByPanelId[panelId] else { return }
        let previousState = verification.state
        switch nextState {
        case .pending:
            verification.state = nextState
            agentWakeVerificationsByPanelId[panelId] = verification
        case .succeeded:
            discardAgentWakeVerification(panelId: panelId)
        case .failed(let reason):
            verification.deadlineTask?.cancel()
            verification.deadlineTask = nil
            verification.state = nextState
            agentWakeVerificationsByPanelId[panelId] = verification
            guard previousState != nextState else { return }
            presentAgentWakeFailure(verification, reason: reason, panelId: panelId)
        }
    }

    private func presentAgentWakeFailure(
        _ verification: AgentWakeVerification,
        reason: AgentWakeFailureReason,
        panelId: UUID
    ) {
        let failure = AgentWakeFailure(
            reason: reason,
            agentDisplayName: verification.agent.agentDisplayName,
            commandText: verification.commandText,
            agent: verification.agent
        )
        if let terminalPanel = terminalPanel(for: panelId) {
            terminalPanel.onRequestAgentWakeRetry = { [weak self] in
                self?.retryAgentWake(panelId: panelId)
            }
            terminalPanel.onDismissAgentWakeFailure = { [weak self] in
                self?.dismissAgentWakeFailure(panelId: panelId)
            }
            terminalPanel.agentWakeFailure = failure
        }
        refreshAgentWakeFailureStatusEntry()
        AppDelegate.shared?.notificationStore?.addNotification(
            tabId: id,
            surfaceId: panelId,
            title: String(
                format: String(
                    localized: "agentWake.notification.title",
                    defaultValue: "%@ didn't resume"
                ),
                failure.agentDisplayName
            ),
            subtitle: "",
            body: reason.detail
        )
    }

    private func clearAgentWakeFailurePresentation(on terminalPanel: TerminalPanel) {
        terminalPanel.onRequestAgentWakeRetry = nil
        terminalPanel.onDismissAgentWakeFailure = nil
        if terminalPanel.agentWakeFailure != nil {
            terminalPanel.agentWakeFailure = nil
        }
    }

    private func refreshAgentWakeFailureStatusEntry() {
        let key = Self.agentWakeFailedStatusKey
        let failedCount = agentWakeVerificationsByPanelId.values.filter {
            $0.state.failureReason != nil
        }.count
        guard failedCount > 0 else {
            if statusEntries[key] != nil {
                statusEntries.removeValue(forKey: key)
            }
            return
        }
        let value = failedCount == 1
            ? String(localized: "agentWake.status.single", defaultValue: "Agent didn't resume")
            : String(
                format: String(
                    localized: "agentWake.status.multiple",
                    defaultValue: "%ld agents didn't resume"
                ),
                failedCount
            )
        guard statusEntries[key]?.value != value else { return }
        statusEntries[key] = SidebarStatusEntry(
            key: key,
            value: value,
            icon: "exclamationmark.triangle",
            color: "#FF9500",
            timestamp: Date()
        )
    }
}
