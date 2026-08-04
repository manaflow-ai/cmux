import Darwin
import Foundation
import Observation

/// Owns agent runtime maps that affect whether structured sidebar statuses are visible.
@MainActor
@Observable
final class WorkspaceSidebarAgentRuntimeObservationModel {
    @ObservationIgnored
    private(set) var agentPIDs: [String: pid_t] = [:]
    @ObservationIgnored
    private(set) var agentPIDProcessIdentitiesByKey: [String: AgentPIDProcessIdentity] = [:]
    @ObservationIgnored
    private(set) var agentPIDPanelIdsByKey: [String: UUID] = [:]
    @ObservationIgnored
    private(set) var agentPIDKeysByPanelId: [UUID: Set<String>] = [:]
    @ObservationIgnored
    private(set) var agentLifecycleStatesByPanelId: [UUID: [String: AgentHibernationLifecycleState]] = [:]
    @ObservationIgnored
    private var agentLifecycleReconciliationState = AgentLifecycleReconciliationState()
    @ObservationIgnored
    private let agentProcessExitMonitor = AgentProcessExitMonitor()
    @ObservationIgnored
    private(set) var changeGeneration: UInt64 = 0

    var agentLifecycleEvidencePanelIds: Set<UUID> {
        agentLifecycleReconciliationState.panelIdsWithEvidence
    }

    @ObservationIgnored
    private(set) var changeObservers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Emits whenever any runtime map changes.
    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            changeObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.changeObservers[id] = nil }
            }
        }
    }

    func setAgentPIDs(_ newValue: [String: pid_t]) {
        guard agentPIDs != newValue else { return }
        agentPIDs = newValue
        notifyChanged()
    }

    func setAgentPIDProcessIdentitiesByKey(_ newValue: [String: AgentPIDProcessIdentity]) {
        guard agentPIDProcessIdentitiesByKey != newValue else { return }
        agentPIDProcessIdentitiesByKey = newValue
        notifyChanged()
    }

    func setAgentPIDPanelIdsByKey(_ newValue: [String: UUID]) {
        guard agentPIDPanelIdsByKey != newValue else { return }
        agentPIDPanelIdsByKey = newValue
        notifyChanged()
    }

    func setAgentPIDKeysByPanelId(_ newValue: [UUID: Set<String>]) {
        guard agentPIDKeysByPanelId != newValue else { return }
        agentPIDKeysByPanelId = newValue
        notifyChanged()
    }

    @discardableResult
    func setAgentHookLifecycle(
        key: String,
        panelId: UUID,
        lifecycle: AgentHibernationLifecycleState,
        isBuiltIn: Bool,
        processGeneration: AgentPIDProcessIdentity? = nil
    ) -> Bool {
        let accepted = agentLifecycleReconciliationState.setHookLifecycle(
            key: key,
            panelId: panelId,
            lifecycle: lifecycle,
            isBuiltIn: isBuiltIn,
            processGeneration: processGeneration
        )
        publishReconciledLifecycle()
        return accepted
    }

    func beginAgentFeedAttention(
        key: String,
        panelId: UUID,
        isBuiltIn: Bool,
        processGeneration: AgentPIDProcessIdentity? = nil
    ) -> AgentFeedAttentionToken? {
        let token = agentLifecycleReconciliationState.beginFeedAttention(
            key: key,
            panelId: panelId,
            isBuiltIn: isBuiltIn,
            processGeneration: processGeneration
        )
        publishReconciledLifecycle()
        return token
    }

    func hasAgentFeedAttention(key: String, panelId: UUID) -> Bool {
        agentLifecycleReconciliationState.hasFeedAttention(
            key: key,
            panelId: panelId
        )
    }

    @discardableResult
    func endAgentFeedAttention(
        key: String,
        panelId: UUID,
        token: AgentFeedAttentionToken
    ) -> Bool {
        let ended = agentLifecycleReconciliationState.endFeedAttention(
            key: key,
            panelId: panelId,
            token: token
        )
        publishReconciledLifecycle()
        return ended
    }

    func recordAgentProcessGeneration(
        key: String,
        panelId: UUID,
        generation: AgentPIDProcessIdentity,
        isBuiltIn: Bool
    ) {
        agentLifecycleReconciliationState.recordProcessGeneration(
            key: key,
            panelId: panelId,
            generation: generation,
            isBuiltIn: isBuiltIn
        )
        publishReconciledLifecycle()
    }

    @discardableResult
    func recordUnidentifiedAgentProcessExit(
        key: String,
        panelId: UUID,
        isBuiltIn: Bool
    ) -> Bool {
        let recorded = agentLifecycleReconciliationState
            .recordUnidentifiedProcessExit(
            key: key,
            panelId: panelId,
            isBuiltIn: isBuiltIn
        )
        if recorded {
            publishReconciledLifecycle()
        }
        return recorded
    }

    @discardableResult
    func recordAgentProcessExit(
        key: String,
        panelId: UUID,
        generation: AgentPIDProcessIdentity
    ) -> Bool {
        let invalidated = agentLifecycleReconciliationState.recordProcessExit(
            key: key,
            panelId: panelId,
            generation: generation
        )
        publishReconciledLifecycle()
        return invalidated
    }

    @discardableResult
    func removeAgentLifecycleKey(key: String, panelId: UUID) -> Bool {
        let removed = agentLifecycleReconciliationState.removeKey(
            key: key,
            panelId: panelId
        )
        publishReconciledLifecycle()
        return removed
    }

    @discardableResult
    func removeAgentHookLifecycle(key: String, panelId: UUID) -> Bool {
        let removed = agentLifecycleReconciliationState.removeHook(
            key: key,
            panelId: panelId
        )
        publishReconciledLifecycle()
        return removed
    }

    @discardableResult
    func removeAgentLifecyclePanel(_ panelId: UUID) -> Bool {
        let removed = agentLifecycleReconciliationState.removePanel(panelId)
        publishReconciledLifecycle()
        return removed
    }

    func removeAllAgentLifecycle() {
        agentLifecycleReconciliationState.removeAll()
        publishReconciledLifecycle()
    }

    func transferableAgentLifecycleReconciliationSnapshot(
        for panelId: UUID
    ) -> AgentLifecycleReconciliationState {
        agentLifecycleReconciliationState.panelRuntimeSnapshot(
            for: panelId
        )
    }

    func adoptAgentLifecycleReconciliationSnapshot(
        _ snapshot: AgentLifecycleReconciliationState,
        panelId: UUID
    ) {
        agentLifecycleReconciliationState.replacePanel(
            panelId,
            with: snapshot
        )
        publishReconciledLifecycle()
    }

    func observeAgentProcessExit(
        key: String,
        generation: AgentPIDProcessIdentity,
        onExit: @escaping @MainActor (String, AgentPIDProcessIdentity) -> Void
    ) {
        agentProcessExitMonitor.observe(
            key: key,
            generation: generation,
            onExit: onExit
        )
    }

    func cancelAgentProcessExitObservation(key: String) {
        agentProcessExitMonitor.cancel(key: key)
    }

    func cancelAllAgentProcessExitObservations() {
        agentProcessExitMonitor.cancelAll()
    }

    private func publishReconciledLifecycle() {
        let newValue = agentLifecycleReconciliationState.resolvedStatesByPanelId
        guard agentLifecycleStatesByPanelId != newValue else { return }
        agentLifecycleStatesByPanelId = newValue
        notifyChanged()
    }

    private func notifyChanged() {
        changeGeneration &+= 1
        // Termination cleanup arrives through a separate MainActor task. If
        // that task is delayed by sidebar work, publication is the
        // authoritative reconciliation point so dead observers cannot make
        // every later event progressively more expensive.
        var terminatedObserverIDs: [UUID] = []
        for (id, continuation) in changeObservers {
            if case .terminated = continuation.yield(()) {
                terminatedObserverIDs.append(id)
            }
        }
        for id in terminatedObserverIDs {
            changeObservers[id] = nil
        }
    }
}
