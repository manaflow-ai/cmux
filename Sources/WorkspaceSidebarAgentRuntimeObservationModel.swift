import Darwin
import Foundation
import Observation

/// Owns agent runtime maps that affect whether structured sidebar statuses are visible.
@MainActor
@Observable
final class WorkspaceSidebarAgentRuntimeObservationModel {
    /// One native lifecycle event, bound at receipt to a registered agent's
    /// process birth. Evidence time never changes while projecting snapshots.
    struct LifecycleEvidence: Equatable, Sendable {
        let agentPIDKey: String
        let processIdentity: AgentPIDProcessIdentity
        let lifecycle: AgentHibernationLifecycleState
        let observedAt: Date
        let isError: Bool
    }

    @ObservationIgnored
    private(set) var lifecycleEvidenceByPanelID: [UUID: [String: LifecycleEvidence]] = [:]

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
    private(set) var changeGeneration: UInt64 = 0

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
        pruneLifecycleEvidence()
        notifyChanged()
    }

    func setAgentPIDProcessIdentitiesByKey(_ newValue: [String: AgentPIDProcessIdentity]) {
        guard agentPIDProcessIdentitiesByKey != newValue else { return }
        agentPIDProcessIdentitiesByKey = newValue
        pruneLifecycleEvidence()
        notifyChanged()
    }

    func setAgentPIDPanelIdsByKey(_ newValue: [String: UUID]) {
        guard agentPIDPanelIdsByKey != newValue else { return }
        agentPIDPanelIdsByKey = newValue
        pruneLifecycleEvidence()
        notifyChanged()
    }

    func setAgentPIDKeysByPanelId(_ newValue: [UUID: Set<String>]) {
        guard agentPIDKeysByPanelId != newValue else { return }
        agentPIDKeysByPanelId = newValue
        pruneLifecycleEvidence()
        notifyChanged()
    }

    func setAgentLifecycleStatesByPanelId(_ newValue: [UUID: [String: AgentHibernationLifecycleState]]) {
        guard agentLifecycleStatesByPanelId != newValue else { return }
        agentLifecycleStatesByPanelId = newValue
        pruneLifecycleEvidence()
        notifyChanged()
    }

    func recordLifecycleEvidence(panelID: UUID, statusKey: String, evidence: LifecycleEvidence?) {
        guard lifecycleEvidenceByPanelID[panelID]?[statusKey] != evidence else { return }
        if let evidence {
            lifecycleEvidenceByPanelID[panelID, default: [:]][statusKey] = evidence
        } else {
            lifecycleEvidenceByPanelID[panelID]?.removeValue(forKey: statusKey)
            if lifecycleEvidenceByPanelID[panelID]?.isEmpty == true { lifecycleEvidenceByPanelID.removeValue(forKey: panelID) }
        }
        notifyChanged()
    }

    private func pruneLifecycleEvidence() {
        var survivingByPanel: [UUID: [String: LifecycleEvidence]] = [:]
        for (panelID, states) in lifecycleEvidenceByPanelID {
            let surviving = states.filter { statusKey, evidence in
                agentPIDPanelIdsByKey[evidence.agentPIDKey] == panelID
                    && agentPIDs[evidence.agentPIDKey] == evidence.processIdentity.pid
                    && agentPIDProcessIdentitiesByKey[evidence.agentPIDKey] == evidence.processIdentity
                    && agentLifecycleStatesByPanelId[panelID]?[statusKey] == evidence.lifecycle
            }
            if !surviving.isEmpty { survivingByPanel[panelID] = surviving }
        }
        lifecycleEvidenceByPanelID = survivingByPanel
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
