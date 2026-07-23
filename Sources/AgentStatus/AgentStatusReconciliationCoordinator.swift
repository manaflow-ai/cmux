import CmuxFoundation
import Foundation

/// Runs one process-wide foreground-agent reconciliation sweep at a time.
@MainActor
final class AgentStatusReconciliationCoordinator {
    typealias Detector = @Sendable (
        [UUID: AgentPIDProcessIdentity],
        [UUID: [AgentPIDProcessIdentity: Set<String>]]
    ) async -> [UUID: String]

    private static let minimumSweepInterval: Duration = .seconds(30)

    private let detector: Detector
    private var detectorTask: Task<Void, Never>?
    private var lastSweepStartedAt: ContinuousClock.Instant?
    private var outputActivityGates: [UUID: AtomicBooleanGate] = [:]

    init(detector: @escaping Detector = AgentStatusReconciliationCoordinator.detectForegroundAgentStatusKeys) {
        self.detector = detector
    }

    func outputActivityGate(panelId: UUID, isTracked: Bool) -> AtomicBooleanGate {
        if let gate = outputActivityGates[panelId] {
            gate.storeRelease(isTracked)
            return gate
        }
        let gate = AtomicBooleanGate(isTracked)
        outputActivityGates[panelId] = gate
        return gate
    }

    func setOutputActivityTracking(panelId: UUID, isTracked: Bool) {
        outputActivityGates[panelId]?.storeRelease(isTracked)
    }

    func removeOutputActivityGate(panelId: UUID) {
        outputActivityGates.removeValue(forKey: panelId)?.storeRelease(false)
    }

    /// Reconciles cheap evidence every cycle and starts at most one foreground detector.
    @discardableResult
    func reconcile(
        tabManagers: [TabManager],
        at sweepInstant: ContinuousClock.Instant = .now,
        observedAt: Date = .now
    ) -> Task<Void, Never>? {
        if let lastSweepStartedAt,
           lastSweepStartedAt.duration(to: sweepInstant) < Self.minimumSweepInterval {
            return nil
        }

        for manager in tabManagers {
            for workspace in manager.tabs {
                workspace.clearStaleAgentPIDs()
                workspace.reconcileAgentStatuses(now: observedAt)
            }
        }

        var foregroundProcessIdentities: [UUID: AgentPIDProcessIdentity] = [:]
        var rootStatusKeysByPanelId: [UUID: [AgentPIDProcessIdentity: Set<String>]] = [:]
        var panelIds = Set<UUID>()
        for manager in tabManagers {
            for workspace in manager.tabs {
                let probe = workspace.agentStatusForegroundProbe()
                foregroundProcessIdentities.merge(probe.foregroundProcessIdentities) { _, latest in latest }
                rootStatusKeysByPanelId.merge(probe.rootStatusKeysByPanelId) { _, latest in latest }
                panelIds.formUnion(probe.panelIds)
            }
        }
        lastSweepStartedAt = sweepInstant
        guard !panelIds.isEmpty, detectorTask == nil else { return nil }

        let detector = detector
        let foregroundIdentitySnapshot = foregroundProcessIdentities
        let rootStatusKeySnapshot = rootStatusKeysByPanelId
        let trackedPanelIds = panelIds
        let task = Task { @MainActor [weak self] in
            let observedStatusKeys = await detector(
                foregroundIdentitySnapshot,
                rootStatusKeySnapshot
            )
            guard let self else { return }
            defer { self.detectorTask = nil }
            guard !Task.isCancelled else { return }

            let reconciledAt = Date.now
            var workspacesByID: [UUID: Workspace] = [:]
            for panelId in trackedPanelIds {
                guard let owner = AppDelegate.shared?.workspaceContainingPanel(panelId: panelId),
                      owner.workspace.agentStatusForegroundProbeIsCurrent(
                          panelId: panelId,
                          foregroundProcessIdentity: foregroundIdentitySnapshot[panelId],
                          rootStatusKeys: rootStatusKeySnapshot[panelId] ?? [:]
                      ) else {
                    continue
                }
                owner.workspace.noteAgentStatusForegroundAgent(
                    statusKey: observedStatusKeys[panelId] ?? nil,
                    panelId: panelId,
                    observedAt: observedAt
                )
                workspacesByID[owner.workspace.id] = owner.workspace
            }
            for workspace in workspacesByID.values {
                workspace.reconcileAgentStatuses(now: reconciledAt)
            }
        }
        detectorTask = task
        return task
    }

    private nonisolated static func detectForegroundAgentStatusKeys(
        foregroundProcessIdentities: [UUID: AgentPIDProcessIdentity],
        rootStatusKeysByPanelId: [UUID: [AgentPIDProcessIdentity: Set<String>]]
    ) async -> [UUID: String] {
        // libproc inspection is synchronous; detaching prevents the process-wide
        // snapshot from inheriting the coordinator's MainActor isolation.
        await Task.detached(priority: .utility) {
            let snapshot = CmuxTopProcessSnapshot.captureCached(
                includeProcessDetails: false,
                includeCMUXScope: false,
                maximumAge: 5
            )
            var result: [UUID: String] = [:]
            for (panelId, foregroundIdentity) in foregroundProcessIdentities {
                let foregroundPID = Int(foregroundIdentity.pid)
                guard AgentPIDProcessIdentity(pid: foregroundIdentity.pid) == foregroundIdentity else {
                    continue
                }
                if let definition = CmuxTopProcessSnapshot.codingAgentDefinition(
                    foregroundPID: foregroundPID
                ), AgentPIDProcessIdentity(pid: foregroundIdentity.pid) == foregroundIdentity {
                    result[panelId] = agentStatusKey(forDetectedAgentID: definition.id)
                    continue
                }
                let rootStatusKeys = rootStatusKeysByPanelId[panelId] ?? [:]
                let matches = rootStatusKeys.reduce(into: Set<String>()) { matches, root in
                    let (rootIdentity, statusKeys) = root
                    guard AgentPIDProcessIdentity(pid: rootIdentity.pid) == rootIdentity,
                          snapshot.descendantPIDs(rootPID: Int(rootIdentity.pid), includeRoot: true)
                              .contains(foregroundPID) else {
                        return
                    }
                    matches.formUnion(statusKeys)
                }
                guard matches.count == 1,
                      let statusKey = matches.first,
                      AgentPIDProcessIdentity(pid: foregroundIdentity.pid) == foregroundIdentity else {
                    continue
                }
                result[panelId] = statusKey
            }
            return result
        }.value
    }

    private nonisolated static func agentStatusKey(forDetectedAgentID agentID: String) -> String? {
        let statusKey = FeedCoordinator.lifecycleStatusKey(forSource: agentID)
        return AgentHibernationLifecycleStatusKeys.isAllowed(statusKey) ? statusKey : nil
    }
}
