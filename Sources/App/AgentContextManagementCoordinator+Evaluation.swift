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
            states[surfaceID] = state
            return
        }
        state.injectionInFlight = false
        state.preservationCompleted = false
        state.recoveryAwaitingLifecycleBoundary = true
        state.recoveryObservedRunning = false
        state.unsafeClearNotificationSent = false
        state.pressure = AgentContextPressureSnapshot()
        userInputObservedBeforePressure.remove(surfaceID)
        state.userInputObserved = false
        states[surfaceID] = state
        owner.clearPressureStatus(key: Self.statusKey(for: surfaceID), panelId: surfaceID)
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

    private func notifyUnsafeClear(owner: PanelOwner, surfaceID: UUID, reason: AgentContextInjectionBlockReason) {
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
