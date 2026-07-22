import Foundation

extension TabManager {
    /// Reconciles live process identity off-main, then projects every tracked status.
    func reconcileAgentStatusesPeriodically() {
        for tab in tabs { tab.clearStaleAgentPIDs() }

        var foregroundPIDs: [UUID: Int] = [:]
        var rootStatusKeysByPanelId: [UUID: [Int: String]] = [:]
        var panelIds = Set<UUID>()
        for tab in tabs {
            let probe = tab.agentStatusForegroundProbe()
            foregroundPIDs.merge(probe.foregroundPIDs) { _, latest in latest }
            rootStatusKeysByPanelId.merge(probe.rootStatusKeysByPanelId) { _, latest in latest }
            panelIds.formUnion(probe.panelIds)
        }
        guard !panelIds.isEmpty else { return }
        let foregroundPIDSnapshot = foregroundPIDs
        let rootStatusKeySnapshot = rootStatusKeysByPanelId
        let trackedPanelIds = panelIds

        // libproc inspection is synchronous. This detached task is the bounded
        // bridge that keeps the 30-second safety sweep off the main actor.
        Task { @MainActor [weak self] in
            let observedStatusKeys = await Task.detached(priority: .utility) {
                Self.detectForegroundAgentStatusKeys(
                    foregroundPIDs: foregroundPIDSnapshot,
                    rootStatusKeysByPanelId: rootStatusKeySnapshot
                )
            }.value
            guard let self else { return }
            let observedAt = Date.now
            for panelId in trackedPanelIds {
                guard let owner = AppDelegate.shared?.workspaceContainingPanel(panelId: panelId) else {
                    continue
                }
                owner.workspace.noteAgentStatusForegroundAgent(
                    statusKey: observedStatusKeys[panelId] ?? nil,
                    panelId: panelId,
                    observedAt: observedAt
                )
            }
            for tab in self.tabs { tab.reconcileAgentStatuses(now: observedAt) }
        }
    }

    nonisolated private static func detectForegroundAgentStatusKeys(
        foregroundPIDs: [UUID: Int],
        rootStatusKeysByPanelId: [UUID: [Int: String]]
    ) -> [UUID: String] {
        let snapshot = CmuxTopProcessSnapshot.capture(
            includeProcessDetails: false,
            includeCMUXScope: false
        )
        var result: [UUID: String] = [:]
        for (panelId, foregroundPID) in foregroundPIDs {
            if let definition = CmuxTopProcessSnapshot.codingAgentDefinition(
                foregroundPID: foregroundPID
            ) {
                result[panelId] = agentStatusKey(forDetectedAgentID: definition.id)
                continue
            }
            let rootStatusKeys = rootStatusKeysByPanelId[panelId] ?? [:]
            result[panelId] = rootStatusKeys.first { rootPID, _ in
                snapshot.descendantPIDs(rootPID: rootPID, includeRoot: true)
                    .contains(foregroundPID)
            }?.value
        }
        return result
    }

    nonisolated private static func agentStatusKey(forDetectedAgentID agentID: String) -> String? {
        let statusKey = agentID == "claude" ? "claude_code" : agentID
        return AgentHibernationLifecycleStatusKeys.isAllowed(statusKey) ? statusKey : nil
    }
}
