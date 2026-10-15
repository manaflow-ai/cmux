import CmuxFoundation
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
    /// Session identity for journal-backed lifecycle entries. Other sidebar
    /// producers intentionally leave entries unowned so custom projections can
    /// fail closed instead of attaching their state to a later agent session.
    @ObservationIgnored
    private(set) var agentLifecycleSessionIDsByPanelId: [UUID: [String: String]] = [:]
    @ObservationIgnored
    private(set) var changeGeneration: UInt64 = 0

    @ObservationIgnored
    private(set) var changeObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// A runtime mutation can land between the parent building its immutable
    /// row snapshot and installing the row's observation task. Keep one
    /// replay marker for that gap so the first subscriber re-reads current
    /// state instead of waiting for a later agent event.
    @ObservationIgnored
    private var hasUnobservedChange = false

    /// Emits whenever any runtime map changes.
    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            changeObservers[id] = continuation
            if hasUnobservedChange {
                hasUnobservedChange = false
                continuation.yield(())
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.changeObservers[id] = nil
                }
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

    func setAgentLifecycleStatesByPanelId(_ newValue: [UUID: [String: AgentHibernationLifecycleState]]) {
        guard agentLifecycleStatesByPanelId != newValue else { return }
        agentLifecycleStatesByPanelId = newValue
        notifyChanged()
    }

    /// Records or removes the session that owns one panel lifecycle key.
    func setAgentLifecycleSessionID(_ sessionID: String?, key: String, panelId: UUID) {
        if let sessionID, !sessionID.isEmpty {
            guard agentLifecycleSessionIDsByPanelId[panelId]?[key] != sessionID else { return }
            agentLifecycleSessionIDsByPanelId[panelId, default: [:]][key] = sessionID
        } else {
            guard agentLifecycleSessionIDsByPanelId[panelId]?[key] != nil else { return }
            agentLifecycleSessionIDsByPanelId[panelId]?.removeValue(forKey: key)
            if agentLifecycleSessionIDsByPanelId[panelId]?.isEmpty == true {
                agentLifecycleSessionIDsByPanelId.removeValue(forKey: panelId)
            }
        }
        notifyChanged()
    }

    /// Removes lifecycle ownership metadata for one panel.
    func clearAgentLifecycleSessionIDs(panelId: UUID) {
        guard agentLifecycleSessionIDsByPanelId.removeValue(forKey: panelId) != nil else { return }
        notifyChanged()
    }

    /// Removes lifecycle ownership metadata for every panel.
    func clearAllAgentLifecycleSessionIDs() {
        guard !agentLifecycleSessionIDsByPanelId.isEmpty else { return }
        agentLifecycleSessionIDsByPanelId.removeAll()
        notifyChanged()
    }

    private func notifyChanged() {
        changeGeneration &+= 1
        // Termination cleanup arrives through a separate MainActor task. If
        // that task is delayed by sidebar work, publication is the
        // authoritative reconciliation point so dead observers cannot make
        // every later event progressively more expensive.
        var terminatedObserverIDs: [UUID] = []
        var delivered = false
        for (id, continuation) in changeObservers {
            switch continuation.yield(()) {
            case .terminated:
                terminatedObserverIDs.append(id)
            case .enqueued, .dropped:
                delivered = true
            @unknown default:
                break
            }
        }
        for id in terminatedObserverIDs {
            changeObservers[id] = nil
        }
        if !delivered {
            hasUnobservedChange = true
        }
    }
}
