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

    /// Emits whenever any runtime map changes.
    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            changeObservers[id] = continuation
            // Replay once so a subscriber that attached after the last mutation
            // still re-resolves against the current maps.
            continuation.yield(())
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

    func setAgentLifecycleStatesByPanelId(_ newValue: [UUID: [String: AgentHibernationLifecycleState]]) {
        guard agentLifecycleStatesByPanelId != newValue else { return }
        agentLifecycleStatesByPanelId = newValue
        refreshRunningSince(now: Date().timeIntervalSince1970)
        notifyChanged()
    }

    // MARK: - Stale `.running` safety net

    /// How long a `.running` may sit without any lifecycle change before it is
    /// treated as untrustworthy and downgraded to `.unknown`.
    ///
    /// An agent CLI reports `.running` once per turn and `.idle` once per turn.
    /// When the idle report is lost — a killed Stop hook, a hook that never
    /// fires, an agent that dies mid-turn — nothing else can retire the
    /// `.running`: the app's only automatic clear runs when the agent *process*
    /// dies, and these agents sit alive at their own prompt. This bounds that.
    ///
    /// `.unknown` is the deliberate target rather than `.idle`: it renders as
    /// "no agent state" everywhere, and unlike `.idle` it does not satisfy
    /// `AgentHibernationLifecycleState.allowsHibernation`, so a downgrade can
    /// never cause a pane to be torn down.
    ///
    /// ponytail: a flat timeout, not a real quiescence signal. The app has no
    /// per-pane last-output timestamp today; if one is added, gate the
    /// downgrade on it instead of raising this constant.
    static let staleRunningTimeout: TimeInterval = 30 * 60
    private static let staleRunningSweepInterval: Duration = .seconds(120)

    /// When each still-`.running` (panel, key) pair last changed state.
    @ObservationIgnored
    private var runningSinceByPanelId: [UUID: [String: TimeInterval]] = [:]
    @ObservationIgnored
    private var staleRunningSweep: Task<Void, Never>?

    /// Re-stamps newly-running keys and forgets keys that left `.running`.
    /// A key that stays `.running` keeps its original stamp, so the age
    /// measured is "time since this pane last changed state at all".
    private func refreshRunningSince(now: TimeInterval) {
        var updated: [UUID: [String: TimeInterval]] = [:]
        for (panelId, states) in agentLifecycleStatesByPanelId {
            var stamps: [String: TimeInterval] = [:]
            for (key, state) in states where state == .running {
                stamps[key] = runningSinceByPanelId[panelId]?[key] ?? now
            }
            if !stamps.isEmpty {
                updated[panelId] = stamps
            }
        }
        runningSinceByPanelId = updated
        updated.isEmpty ? cancelStaleRunningSweep() : startStaleRunningSweepIfNeeded()
    }

    /// Re-stamps one `.running` key on an explicit lifecycle report, so a long
    /// turn that keeps re-reporting `.running` is not mistaken for a stale one
    /// by the sweep. Only the socket-driven report path calls this; internal
    /// reconciliation that rewrites the same map must not mask a dead agent.
    func noteAgentRunningReport(panelId: UUID, key: String, now: TimeInterval = Date().timeIntervalSince1970) {
        guard agentLifecycleStatesByPanelId[panelId]?[key] == .running else { return }
        runningSinceByPanelId[panelId, default: [:]][key] = now
        startStaleRunningSweepIfNeeded()
    }

    private func startStaleRunningSweepIfNeeded() {
        guard staleRunningSweep == nil else { return }
        staleRunningSweep = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.staleRunningSweepInterval)
                guard !Task.isCancelled, let self else { return }
                self.downgradeStaleRunning(now: Date().timeIntervalSince1970)
            }
        }
    }

    private func cancelStaleRunningSweep() {
        staleRunningSweep?.cancel()
        staleRunningSweep = nil
    }

    /// Downgrades every `.running` older than `staleRunningTimeout` to
    /// `.unknown`. Returns the keys it retired, for tests.
    @discardableResult
    func downgradeStaleRunning(
        now: TimeInterval,
        timeout: TimeInterval = staleRunningTimeout
    ) -> [(panelId: UUID, key: String)] {
        var retired: [(panelId: UUID, key: String)] = []
        var states = agentLifecycleStatesByPanelId
        for (panelId, stamps) in runningSinceByPanelId {
            for (key, since) in stamps where now - since >= timeout {
                guard states[panelId]?[key] == .running else { continue }
                states[panelId]?[key] = .unknown
                retired.append((panelId: panelId, key: key))
            }
        }
        guard !retired.isEmpty else { return [] }
        setAgentLifecycleStatesByPanelId(states)
        return retired
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
