import CmuxSidebar
import CmuxWorkspaces
import Foundation

@MainActor
extension AgentContextManagementCoordinator {
    func evaluate(surfaceID: UUID, owner: PanelOwner) {
        guard var state = states[surfaceID] else { return }
        guard let binding = owner.binding(panelId: surfaceID),
              sameSession(state.binding, binding) else {
            resetForUnboundSession(panelId: surfaceID)
            return
        }
        let input = AgentContextInjectionInput(
            enabled: settings.isEnabled,
            pressureDetected: state.pressure.isUnderPressure,
            pressureConfirmed: state.pressureConfirmation.isConfirmed,
            managedSessionBound: owner.binding(panelId: surfaceID)?.isAgentHookBinding == true,
            provider: state.provider,
            lifecycle: state.lifecycle,
            shellActivity: state.shellActivity,
            dialogOpen: state.dialogOpen || owner.hasDialogOpen(panelId: surfaceID),
            userInputObserved: state.userInputObserved,
            injectionInFlight: state.injectionInFlight,
            action: settings.action,
            preserveState: settings.preservesState,
            preservationCompleted: state.preservationCompleted,
            preservationAwaitingAcknowledgement: state.preservationAwaitingAcknowledgement
        )
        let decision = policy.decide(input)
        structuredLog(
            "gating",
            workspaceID: owner.workspaceID,
            surfaceID: surfaceID,
            detail: "decision=\(String(describing: decision))"
        )
        guard case .inject(let step) = decision else {
            if case .unsafe(let reason) = decision,
               settings.action == .clear,
               !state.unsafeClearNotificationSent {
                state.unsafeClearNotificationSent = true
                states[surfaceID] = state
                notifyUnsafeClear(owner: owner, surfaceID: surfaceID, reason: reason)
            }
            return
        }
        guard let terminal = owner.terminal(panelId: surfaceID) else {
            let shouldNotify = settings.action == .clear && !state.unsafeClearNotificationSent
            if settings.action == .clear {
                state.unsafeClearNotificationSent = true
            }
            states[surfaceID] = state
            if shouldNotify {
                notifyUnsafeClear(
                    owner: owner,
                    surfaceID: surfaceID,
                    reason: .surfaceUnavailable
                )
            }
            structuredLog(
                "injection.rejected",
                workspaceID: owner.workspaceID,
                surfaceID: surfaceID,
                detail: "step=\(step.rawValue) reason=surface-unavailable"
            )
            return
        }

        if step == .preserveState {
            // A new pressure episode gets a fresh opportunity to preserve
            // state, even if an earlier unsafe-clear notification was sent.
            state.unsafeClearNotificationSent = false
            guard let handoffPath = owner.contextHandoffFileURL(panelId: surfaceID) else {
                state.unsafeClearNotificationSent = true
                state.preservationAwaitingAcknowledgement = true
                state.preservationHandoffPath = nil
                state.preservationRequestedAt = nil
                state.preservationVerificationInFlight = false
                states[surfaceID] = state
                notifyUnsafeClear(
                    owner: owner,
                    surfaceID: surfaceID,
                    reason: .preservationUnavailable
                )
                structuredLog(
                    "injection.rejected",
                    workspaceID: owner.workspaceID,
                    surfaceID: surfaceID,
                    detail: "step=\(step.rawValue) reason=handoff-path-unavailable"
                )
                return
            }
            state.preservationHandoffPath = handoffPath
            state.preservationRequestedAt = Date()
            state.preservationCompleted = false
            state.preservationVerificationInFlight = false
        }

        state.injectionInFlight = true
        // Clear detector occurrence history at the tee boundary before the
        // provider receives recovery input. The tee owns parser mutation; this
        // call only publishes an event-driven reset request.
        state.detectorGeneration = terminal.surface.resetContextPressureDetectors()
        states[surfaceID] = state
        structuredLog(
            "detector-reset-requested",
            workspaceID: owner.workspaceID,
            surfaceID: surfaceID,
            detail: "step=\(step.rawValue) generation=\(state.detectorGeneration)"
        )
        let text: String
        switch step {
        case .preserveState:
            text = String(localized: "agentContext.preserveInstruction", defaultValue: "Before starting a fresh context, write a brief handoff note to .cmux-context-handoff.md in the current working directory, including the current task state and next steps. The next context should read it before continuing.")
        case .compact:
            text = state.provider.recoveryCommand(for: .compact)
        case .clear:
            text = state.provider.recoveryCommand(for: .clear)
        }
        let accepted = terminal.surface.sendContextManagementInput(text + "\n")
        guard accepted else {
            state.injectionInFlight = false
            if step == .preserveState {
                state.preservationHandoffPath = nil
                state.preservationRequestedAt = nil
                state.preservationVerificationInFlight = false
            }
            if settings.action == .clear, !state.unsafeClearNotificationSent {
                state.unsafeClearNotificationSent = true
                states[surfaceID] = state
                notifyUnsafeClear(
                    owner: owner,
                    surfaceID: surfaceID,
                    reason: .surfaceUnavailable
                )
                structuredLog(
                    "injection.rejected",
                    workspaceID: owner.workspaceID,
                    surfaceID: surfaceID,
                    detail: "step=\(step.rawValue) reason=surface-unavailable"
                )
                return
            }
            states[surfaceID] = state
            structuredLog(
                "injection.rejected",
                workspaceID: owner.workspaceID,
                surfaceID: surfaceID,
                detail: "step=\(step.rawValue) reason=surface-unavailable"
            )
            return
        }
        notifyInjection(owner: owner, surfaceID: surfaceID, step: step, command: text)
        if step == .preserveState {
            state.preservationAwaitingAcknowledgement = true
            state.preservationObservedRunning = false
            state.injectionInFlight = false
            state.preservationVerificationInFlight = false
            states[surfaceID] = state
            return
        }
        state.injectionInFlight = false
        state.preservationCompleted = false
        state.recoveryAwaitingLifecycleBoundary = true
        state.recoveryObservedRunning = false
        state.unsafeClearNotificationSent = false
        state.preservationHandoffPath = nil
        state.preservationRequestedAt = nil
        state.preservationVerificationInFlight = false
        state.pressure = AgentContextPressureSnapshot()
        state.pressureConfirmation.reset()
        userInputObservedBeforePressure.remove(surfaceID)
        state.userInputObserved = false
        states[surfaceID] = state
        owner.clearPressureStatus(key: Self.statusKey(for: surfaceID), panelId: surfaceID)
    }

    /// Verifies a preservation request after the provider's real idle boundary.
    ///
    /// The lifecycle transition is necessary but not sufficient: the provider
    /// must also have created a fresh, non-empty handoff file after cmux asked
    /// for it. The actor performs filesystem work off the main actor and
    /// returns one value back through this coordinator's event-driven lane.
    func beginPreservationVerification(
        panelId: UUID,
        path: URL,
        requestedAt: Date
    ) {
        let verifier = handoffVerifier
        preservationVerificationTasks[panelId]?.cancel()
        preservationVerificationRequestedAtByPanel[panelId] = requestedAt
        preservationVerificationTasks[panelId] = Task { @MainActor [weak self, verifier] in
            let result = await verifier.verify(path: path, requestedAt: requestedAt)
            guard !Task.isCancelled else { return }
            self?.finishPreservationVerification(
                panelId: panelId,
                path: path,
                requestedAt: requestedAt,
                result: result
            )
        }
    }

    private func finishPreservationVerification(
        panelId: UUID,
        path: URL,
        requestedAt: Date,
        result: AgentContextHandoffVerifier.Result
    ) {
        guard preservationVerificationRequestedAtByPanel[panelId] == requestedAt else {
            return
        }
        preservationVerificationTasks.removeValue(forKey: panelId)
        preservationVerificationRequestedAtByPanel.removeValue(forKey: panelId)
        guard var state = states[panelId],
              state.preservationAwaitingAcknowledgement,
              state.preservationHandoffPath == path,
              state.preservationRequestedAt == requestedAt else {
            return
        }
        state.preservationVerificationInFlight = false
        let expectedBinding = state.binding
        let currentOwner = owner(for: panelId, preferredWorkspaceID: nil).flatMap { owner in
            owner.binding(panelId: panelId).flatMap { binding in
                sameSession(expectedBinding, binding) ? owner : nil
            }
        }
        switch result {
        case .written:
            state.preservationAwaitingAcknowledgement = false
            state.preservationObservedRunning = false
            state.preservationCompleted = true
            states[panelId] = state
            if let currentOwner {
                structuredLog(
                    "preservation.acknowledged",
                    workspaceID: currentOwner.workspaceID,
                    surfaceID: panelId,
                    detail: "handoff-file=written"
                )
                evaluate(surfaceID: panelId, owner: currentOwner)
            }
        case .missing, .notRegularFile, .empty, .stale, .unreadable:
            // Keep the preservation phase pending and fail closed. The user
            // notification explains that cmux will not type `/clear` without
            // durable evidence; a later explicit user input starts a fresh
            // pressure episode and clears this gate.
            state.unsafeClearNotificationSent = currentOwner.map { _ in true } ?? false
            if case .none = currentOwner {
                // A transfer may temporarily remove every owner. Allow the
                // destination binding callback to request preservation again.
                state.preservationAwaitingAcknowledgement = false
            }
            states[panelId] = state
            if let currentOwner {
                structuredLog(
                    "preservation.rejected",
                    workspaceID: currentOwner.workspaceID,
                    surfaceID: panelId,
                    detail: "handoff-file=\(result.rawValue)"
                )
                notifyUnsafeClear(
                    owner: currentOwner,
                    surfaceID: panelId,
                    reason: .preservationUnavailable
                )
            }
        }
    }

    /// Cancels a pending handoff verification without touching panel state.
    func cancelPreservationVerification(panelId: UUID) {
        preservationVerificationTasks.removeValue(forKey: panelId)?.cancel()
        preservationVerificationRequestedAtByPanel.removeValue(forKey: panelId)
    }

    private func notifyInjection(
        owner: PanelOwner,
        surfaceID: UUID,
        step: AgentContextInjectionStep,
        command: String
    ) {
        if case .workspace(let workspace) = owner {
            workspace.sidebarMetadata.appendLogEntry(
                message: String(localized: "sidebar.agentContext.injectedLog", defaultValue: "Context recovery input sent to the managed agent."),
                level: .success,
                source: "agent-context"
            )
        }
        let subtitle: String
        switch step {
        case .preserveState:
            subtitle = String(localized: "agentContext.notification.preserveSubtitle", defaultValue: "handoff note")
        case .compact, .clear:
            subtitle = command
        }
        AppDelegate.shared?.notificationStore?.addNotification(
            tabId: owner.workspaceID,
            surfaceId: surfaceID,
            title: String(localized: "agentContext.notification.title", defaultValue: "Context recovery sent"),
            subtitle: subtitle,
            body: String(localized: "agentContext.notification.body", defaultValue: "cmux sent context-recovery input after the agent reported context pressure."),
            cooldownKey: "agent-context-injection-\(surfaceID.uuidString)-\(step.rawValue)",
            cooldownInterval: 30
        )
        structuredLog("injection", workspaceID: owner.workspaceID, surfaceID: surfaceID, detail: "step=\(step.rawValue)")
    }

    func notifyUnsafeClear(owner: PanelOwner, surfaceID: UUID, reason: AgentContextInjectionBlockReason) {
        AppDelegate.shared?.notificationStore?.addNotification(
            tabId: owner.workspaceID,
            surfaceId: surfaceID,
            title: String(localized: "agentContext.notification.unsafeTitle", defaultValue: "Context clear needs your input"),
            subtitle: "",
            body: String(localized: "agentContext.notification.unsafeBody", defaultValue: "Context pressure was detected, but cmux could not prove a safe idle agent prompt. Return to the agent prompt and choose the provider's recovery command manually."),
            cooldownKey: "agent-context-unsafe-clear-\(surfaceID.uuidString)",
            cooldownInterval: 60
        )
        structuredLog(
            "unsafe-clear",
            workspaceID: owner.workspaceID,
            surfaceID: surfaceID,
            detail: "reason=\(reason.rawValue)"
        )
    }
}
