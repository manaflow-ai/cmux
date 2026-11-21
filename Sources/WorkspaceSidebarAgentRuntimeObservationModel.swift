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

    @ObservationIgnored
    private(set) var passiveChangeObservers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Emits whenever any runtime map changes, without counting as an
    /// observer of ``changes()``: it never takes or suppresses the replay
    /// that `hasUnobservedChange` holds for the next row subscriber, so a
    /// long-lived listener (the custom-sidebar change monitor) can't leave a
    /// row that subscribes later stale.
    func passiveChanges() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            passiveChangeObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.passiveChangeObservers[id] = nil
                }
            }
        }
    }

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

    private func notifyChanged() {
        changeGeneration &+= 1
        for (id, continuation) in passiveChangeObservers {
            if case .terminated = continuation.yield(()) {
                passiveChangeObservers[id] = nil
            }
        }
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
