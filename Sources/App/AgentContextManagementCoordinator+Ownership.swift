import CmuxWorkspaces
import Foundation

@MainActor
extension AgentContextManagementCoordinator {
    func provider(for panelId: UUID, preferredWorkspaceID: UUID? = nil) -> AgentContextProvider? {
        owner(for: panelId, preferredWorkspaceID: preferredWorkspaceID)
            .flatMap { $0.binding(panelId: panelId) }
            .flatMap { AgentContextProvider(managedAgentKind: $0.kind) }
    }

    func owner(for panelId: UUID, preferredWorkspaceID: UUID?) -> PanelOwner? {
        if let preferredWorkspaceID,
           let manager = AppDelegate.shared?.tabManagerFor(tabId: preferredWorkspaceID),
           let workspace = manager.workspacesById[preferredWorkspaceID],
           workspace.panels[panelId] is TerminalPanel {
            return .workspace(workspace)
        }
        if let preferredWorkspaceID,
           let dock = DockSplitStore.liveStores.first(where: {
               $0.workspaceId == preferredWorkspaceID && $0.panels[panelId] is TerminalPanel
           }) {
            return .dock(dock)
        }
        if let dock = DockSplitStore.liveStores.first(where: {
            $0.panels[panelId] is TerminalPanel
        }) {
            return .dock(dock)
        }
        guard let located = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelId,
            preferredWorkspaceId: preferredWorkspaceID
        ) else { return nil }
        return .workspace(located.workspace)
    }

    func bindingDidChange(panelId: UUID) {
        // Transfers can publish the binding before their destination owner is
        // registered. Preserve state until a later lifecycle/shell signal
        // can resolve the new owner; explicit close paths call remove.
        guard let owner = owner(for: panelId, preferredWorkspaceID: nil) else {
            return
        }
        guard let binding = owner.binding(panelId: panelId),
              let provider = AgentContextProvider(managedAgentKind: binding.kind) else {
            owner.setContextPressureMonitoringEnabled(panelId: panelId, enabled: false)
            _ = owner.resetContextPressureDetector(panelId: panelId)
            resetForUnboundSession(panelId: panelId)
            return
        }
        let pendingUserInput = userInputObservedBeforePressure.remove(panelId) != nil
        guard let existingState = states[panelId] else {
            owner.setContextPressureMonitoringEnabled(
                panelId: panelId,
                enabled: settings.isEnabled
            )
            let generation = owner.resetContextPressureDetector(panelId: panelId)
            states[panelId] = makePanelState(
                panelId: panelId,
                provider: provider,
                binding: binding,
                owner: owner,
                detectorGeneration: generation,
                userInputObserved: pendingUserInput
            )
            structuredLog(
                "detector-reset-requested",
                workspaceID: owner.workspaceID,
                surfaceID: panelId,
                detail: "reason=initial-binding generation=\(generation)"
            )
            return
        }
        guard existingState.provider == provider, sameSession(existingState.binding, binding) else {
            let generation = owner.resetContextPressureDetector(panelId: panelId)
            resetForUnboundSession(panelId: panelId)
            states[panelId] = makePanelState(
                panelId: panelId,
                provider: provider,
                binding: binding,
                owner: owner,
                detectorGeneration: generation,
                userInputObserved: pendingUserInput,
                seedLifecycleEvidence: false
            )
            owner.setContextPressureMonitoringEnabled(
                panelId: panelId,
                enabled: settings.isEnabled
            )
            structuredLog(
                "detector-reset-requested",
                workspaceID: owner.workspaceID,
                surfaceID: panelId,
                detail: "reason=replacement-binding generation=\(generation)"
            )
            return
        }
        owner.setContextPressureMonitoringEnabled(
            panelId: panelId,
            enabled: settings.isEnabled
        )
        var state = existingState
        if pendingUserInput {
            _ = cancelPendingRecovery(panelId: panelId, state: &state, owner: owner)
        }
        // A transfer/binding publication requires fresh provider evidence even
        // when the managed session identity is unchanged.
        state.pressureConfirmation.reset()
        // Binding publication is also the lifecycle boundary for transfers.
        // Re-read both authoritative maps before evaluating preserved pressure
        // so source-owner evidence cannot leak into the destination session.
        state.lifecycleByKey = owner.lifecycleEvidence(
            panelId: panelId,
            provider: provider
        )
        state.lifecycle = Self.effectiveLifecycle(from: state.lifecycleByKey.values)
        state.dialogOpen = state.lifecycle == .needsInput
        state.shellActivity = owner.shellActivity(panelId: panelId)
        states[panelId] = state
        if state.pressure.isUnderPressure {
            owner.setPressureStatus(
                SidebarStatusEntry(
                    key: Self.statusKey(for: panelId),
                    value: String(localized: "sidebar.agentContext.pressure", defaultValue: "Context pressure detected"),
                    icon: "exclamationmark.triangle.fill",
                    color: "#D97706",
                    priority: 20
                ),
                key: Self.statusKey(for: panelId),
                panelId: panelId
            )
        }
        evaluate(surfaceID: panelId, owner: owner)
    }

    func resetForUnboundSession(panelId: UUID) {
        cancelPreservationVerification(panelId: panelId)
        states.removeValue(forKey: panelId)
        userInputObservedBeforePressure.remove(panelId)
        if let owner = owner(for: panelId, preferredWorkspaceID: nil) {
            owner.setContextPressureMonitoringEnabled(panelId: panelId, enabled: false)
            owner.clearPressureStatus(key: Self.statusKey(for: panelId), panelId: panelId)
        }
    }
}
