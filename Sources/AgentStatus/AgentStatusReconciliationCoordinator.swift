import Foundation

/// Runs one process-wide foreground-agent reconciliation sweep at a time.
@MainActor
final class AgentStatusReconciliationCoordinator {
    typealias Detector = @Sendable (
        [UUID: AgentPIDProcessIdentity],
        [UUID: [AgentPIDProcessIdentity: String]]
    ) async -> [UUID: String]

    private static let minimumSweepInterval: Duration = .seconds(30)

    private let detector: Detector
    private var sweepTask: Task<Void, Never>?
    private var lastSweepStartedAt: ContinuousClock.Instant?

    init(detector: @escaping Detector = AgentStatusReconciliationCoordinator.detectForegroundAgentStatusKeys) {
        self.detector = detector
    }

    /// Starts a sweep unless one is already running or this cycle was already sampled.
    @discardableResult
    func reconcile(
        tabManagers: [TabManager],
        at sweepInstant: ContinuousClock.Instant = .now,
        observedAt: Date = .now
    ) -> Task<Void, Never>? {
        guard sweepTask == nil else { return nil }
        if let lastSweepStartedAt,
           lastSweepStartedAt.duration(to: sweepInstant) < Self.minimumSweepInterval {
            return nil
        }

        for manager in tabManagers {
            for workspace in manager.tabs {
                workspace.clearStaleAgentPIDs()
            }
        }

        var foregroundProcessIdentities: [UUID: AgentPIDProcessIdentity] = [:]
        var rootStatusKeysByPanelId: [UUID: [AgentPIDProcessIdentity: String]] = [:]
        var panelIds = Set<UUID>()
        for manager in tabManagers {
            for workspace in manager.tabs {
                let probe = workspace.agentStatusForegroundProbe()
                foregroundProcessIdentities.merge(probe.foregroundProcessIdentities) { _, latest in latest }
                rootStatusKeysByPanelId.merge(probe.rootStatusKeysByPanelId) { _, latest in latest }
                panelIds.formUnion(probe.panelIds)
            }
        }
        guard !panelIds.isEmpty else { return nil }

        lastSweepStartedAt = sweepInstant
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
            defer { self.sweepTask = nil }

            let reconciledAt = Date.now
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
            }
            for manager in tabManagers {
                for workspace in manager.tabs {
                    workspace.reconcileAgentStatuses(now: reconciledAt)
                }
            }
        }
        sweepTask = task
        return task
    }

    private nonisolated static func detectForegroundAgentStatusKeys(
        foregroundProcessIdentities: [UUID: AgentPIDProcessIdentity],
        rootStatusKeysByPanelId: [UUID: [AgentPIDProcessIdentity: String]]
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
                let matches = rootStatusKeys.compactMap { rootIdentity, statusKey -> String? in
                    guard AgentPIDProcessIdentity(pid: rootIdentity.pid) == rootIdentity,
                          snapshot.descendantPIDs(rootPID: Int(rootIdentity.pid), includeRoot: true)
                              .contains(foregroundPID) else {
                        return nil
                    }
                    return statusKey
                }
                guard Set(matches).count == 1,
                      AgentPIDProcessIdentity(pid: foregroundIdentity.pid) == foregroundIdentity else {
                    continue
                }
                result[panelId] = matches[0]
            }
            return result
        }.value
    }

    private nonisolated static func agentStatusKey(forDetectedAgentID agentID: String) -> String? {
        let statusKey = agentID == "claude" ? "claude_code" : agentID
        return AgentHibernationLifecycleStatusKeys.isAllowed(statusKey) ? statusKey : nil
    }
}
