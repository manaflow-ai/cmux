import Foundation

/// Why a manual `cmux agent hibernate` request did not hibernate its pane.
enum AgentHibernationManualRefusal: String, Sendable, Equatable {
    /// No terminal with that id exists.
    case surfaceNotFound = "surface_not_found"
    /// The pane has no agent cmux can resume the way it was started.
    case notRestorable = "not_restorable"
    case alreadyHibernated = "already_hibernated"
    /// The terminal has not started, so there is nothing to free.
    case notRunning = "not_running"
    /// The pane is on screen; it would wake again at once.
    case visible
    /// The agent is working or waiting for an answer.
    case agentBusy = "agent_busy"
    /// No hook has reported whether the agent is idle.
    case lifecycleUnknown = "lifecycle_unknown"
    /// The agent reported activity moments ago; its last output may still be
    /// landing even though it reports idle.
    case recentlyActive = "recently_active"
    /// Typed input has not reached the agent yet.
    case unconfirmedInput = "unconfirmed_input"
    /// The pane runs work cmux can't account for, such as background jobs.
    case processScopeUnsafe = "process_scope_unsafe"
    case teardownInProgress = "teardown_in_progress"
    /// The pane changed, or its transcript or background work could not be
    /// protected, between the request and the teardown.
    case teardownRefused = "teardown_refused"

    var message: String {
        switch self {
        case .surfaceNotFound:
            String(localized: "agentHibernation.manual.surfaceNotFound", defaultValue: "No terminal matches that surface.")
        case .notRestorable:
            String(localized: "agentHibernation.manual.notRestorable", defaultValue: "This terminal has no agent that cmux can resume the way it was started.")
        case .alreadyHibernated:
            String(localized: "agentHibernation.manual.alreadyHibernated", defaultValue: "This agent is already hibernated.")
        case .notRunning:
            String(localized: "agentHibernation.manual.notRunning", defaultValue: "This terminal is not running, so there is nothing to hibernate.")
        case .visible:
            String(localized: "agentHibernation.manual.visible", defaultValue: "This agent is on screen. Switch away from it first.")
        case .agentBusy:
            String(localized: "agentHibernation.manual.agentBusy", defaultValue: "This agent is working or waiting for input.")
        case .lifecycleUnknown:
            String(localized: "agentHibernation.manual.lifecycleUnknown", defaultValue: "cmux can't tell whether this agent is idle, so it was left running.")
        case .recentlyActive:
            String(localized: "agentHibernation.manual.recentlyActive", defaultValue: "This agent was active a moment ago. Try again in a few seconds.")
        case .unconfirmedInput:
            String(localized: "agentHibernation.manual.unconfirmedInput", defaultValue: "This agent has typed input it has not received yet.")
        case .processScopeUnsafe:
            String(localized: "agentHibernation.manual.processScopeUnsafe", defaultValue: "This terminal is running other work, such as background jobs, that hibernation would stop.")
        case .teardownInProgress:
            String(localized: "agentHibernation.manual.teardownInProgress", defaultValue: "This agent is already being hibernated.")
        case .teardownRefused:
            String(localized: "agentHibernation.manual.teardownRefused", defaultValue: "The agent changed or its session could not be protected, so it was left running. Try again later.")
        }
    }
}

/// Why `cmux agent wake` did not wake its pane.
enum AgentHibernationWakeRefusal: String, Sendable, Equatable {
    case surfaceNotFound = "surface_not_found"
    case notHibernated = "not_hibernated"
    case teardownInProgress = "teardown_in_progress"
    case resumeUnavailable = "resume_unavailable"

    var message: String {
        switch self {
        case .surfaceNotFound:
            String(localized: "agentHibernation.wake.surfaceNotFound", defaultValue: "No terminal matches that surface.")
        case .notHibernated:
            String(localized: "agentHibernation.wake.notHibernated", defaultValue: "This agent is not hibernated.")
        case .teardownInProgress:
            String(localized: "agentHibernation.wake.teardownInProgress", defaultValue: "This agent is still being hibernated. Try again in a moment.")
        case .resumeUnavailable:
            String(localized: "agentHibernation.wake.resumeUnavailable", defaultValue: "cmux could not start this agent's resume command.")
        }
    }
}

extension AgentHibernationController {
    /// The first reason a manual request must not hibernate `record`, checked
    /// in the order a user can act on. Manual requests skip only the idle
    /// delay, the live-terminal limit and the confirmation window.
    /// Manual requests skip the configured idle delay but still wait this long
    /// after the last activity: a lifecycle hook can report idle just before
    /// the agent's final output lands.
    static let manualMinimumQuietSeconds: TimeInterval = 5

    static func manualHibernationRefusal(
        for record: AgentHibernationRecord,
        teardownInFlight: Bool,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> AgentHibernationManualRefusal? {
        if record.terminalPanel.isAgentHibernated {
            return teardownInFlight || record.terminalPanel.agentHibernationPhase.isAwaitingCommit
                ? .teardownInProgress
                : .alreadyHibernated
        }
        if teardownInFlight { return .teardownInProgress }
        if record.isProtected { return .visible }
        if record.lifecycle == .unknown { return .lifecycleUnknown }
        if !record.lifecycle.allowsHibernation { return .agentBusy }
        if record.hasUnconfirmedTerminalInput { return .unconfirmedInput }
        if now - record.lastActivityAt < manualMinimumQuietSeconds { return .recentlyActive }
        if !record.processSafetyAllowsHibernation { return .processScopeUnsafe }
        if !record.terminalPanel.surface.hasLiveSurface { return .notRunning }
        return nil
    }

    /// Hibernates one named agent now, through the same protected teardown as
    /// routine hibernation: transcript snapshot, background-work check, scoped
    /// termination and a fresh revalidation before commit. Works whether or
    /// not routine hibernation is enabled.
    func hibernateNow(
        workspaceId: UUID?,
        panelId: UUID,
        index: RestorableAgentSessionIndex
    ) async -> AgentHibernationManualRefusal? {
        guard let appDelegate = AppDelegate.shared,
              let located = appDelegate.workspaceContainingPanel(
                  panelId: panelId,
                  preferredWorkspaceId: workspaceId
              ),
              let terminalPanel = located.workspace.panels[panelId] as? TerminalPanel else {
            return .surfaceNotFound
        }
        let key = AgentHibernationPanelKey(workspaceId: located.workspace.id, panelId: panelId)
        let records = appDelegate.agentHibernationRecords(
            index: index,
            activityByPanel: activityByPanel,
            terminalInputByPanel: terminalInputByPanel,
            lifecycleChangeByPanel: lifecycleChangeByPanel
        )
        guard let record = records.first(where: { $0.key == key }) else {
            if terminalPanel.isAgentHibernated {
                return terminalPanel.agentHibernationPhase.isAwaitingCommit
                    ? .teardownInProgress
                    : .alreadyHibernated
            }
            return .notRestorable
        }
        if let refusal = Self.manualHibernationRefusal(
            for: record,
            teardownInFlight: teardownInFlightByPanel[key] != nil
        ) {
            return refusal
        }
        guard let fingerprint = hibernationFingerprint(for: record) else {
            return .notRestorable
        }

        confirmations.removeValue(forKey: key)
        let requestID = UUID()
        teardownInFlightByPanel[key] = InFlightTeardown(requestID: requestID, trigger: .manual)
        let request = ConfirmedTeardownRequest(
            record: record,
            confirmationFingerprint: fingerprint,
            effectiveLastActivityAt: record.lastActivityAt,
            requestID: requestID,
            epoch: teardownValidationEpochByPanel[key] ?? 0,
            generation: teardownValidationGeneration,
            trigger: .manual
        )
        let hibernatedCount = await withCheckedContinuation { continuation in
            beginConfirmedTeardowns([request], onCompletion: { count in
                continuation.resume(returning: count)
            })
        }
        return hibernatedCount > 0 ? nil : .teardownRefused
    }

    /// Wakes one hibernated agent in place without moving focus.
    func wakeNow(workspaceId: UUID?, panelId: UUID) -> AgentHibernationWakeRefusal? {
        guard let located = AppDelegate.shared?.workspaceContainingPanel(
                  panelId: panelId,
                  preferredWorkspaceId: workspaceId
              ),
              let terminalPanel = located.workspace.panels[panelId] as? TerminalPanel else {
            return .surfaceNotFound
        }
        guard terminalPanel.isAgentHibernated else { return .notHibernated }
        guard !terminalPanel.agentHibernationPhase.isAwaitingCommit else { return .teardownInProgress }
        return located.workspace.resumeAgentHibernation(panelId: panelId, focus: false)
            ? nil
            : .resumeUnavailable
    }
}
