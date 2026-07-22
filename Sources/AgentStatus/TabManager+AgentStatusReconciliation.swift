import Foundation

extension TabManager {
    /// Reconciles live process identity off-main, then projects every tracked status.
    func reconcileAgentStatusesPeriodically() {
        for tab in tabs { tab.clearStaleAgentPIDs() }

        var foregroundProcessIdentities: [UUID: AgentPIDProcessIdentity] = [:]
        var rootStatusKeysByPanelId: [UUID: [AgentPIDProcessIdentity: String]] = [:]
        var panelIds = Set<UUID>()
        for tab in tabs {
            let probe = tab.agentStatusForegroundProbe()
            foregroundProcessIdentities.merge(probe.foregroundProcessIdentities) { _, latest in latest }
            rootStatusKeysByPanelId.merge(probe.rootStatusKeysByPanelId) { _, latest in latest }
            panelIds.formUnion(probe.panelIds)
        }
        guard !panelIds.isEmpty else { return }
        let foregroundIdentitySnapshot = foregroundProcessIdentities
        let rootStatusKeySnapshot = rootStatusKeysByPanelId
        let trackedPanelIds = panelIds

        // libproc inspection is synchronous. This detached task is the bounded
        // bridge that keeps the 30-second safety sweep off the main actor.
        Task { @MainActor [weak self] in
            let observedStatusKeys = await Task.detached(priority: .utility) {
                Self.detectForegroundAgentStatusKeys(
                    foregroundProcessIdentities: foregroundIdentitySnapshot,
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
        foregroundProcessIdentities: [UUID: AgentPIDProcessIdentity],
        rootStatusKeysByPanelId: [UUID: [AgentPIDProcessIdentity: String]]
    ) -> [UUID: String] {
        let snapshot = CmuxTopProcessSnapshot.capture(
            includeProcessDetails: false,
            includeCMUXScope: false
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
            guard let match = rootStatusKeys.first(where: { rootIdentity, _ in
                AgentPIDProcessIdentity(pid: rootIdentity.pid) == rootIdentity
                    && snapshot.descendantPIDs(rootPID: Int(rootIdentity.pid), includeRoot: true)
                        .contains(foregroundPID)
            }),
                  AgentPIDProcessIdentity(pid: foregroundIdentity.pid) == foregroundIdentity else {
                continue
            }
            result[panelId] = match.value
        }
        return result
    }

    nonisolated private static func agentStatusKey(forDetectedAgentID agentID: String) -> String? {
        let statusKey = agentID == "claude" ? "claude_code" : agentID
        return AgentHibernationLifecycleStatusKeys.isAllowed(statusKey) ? statusKey : nil
    }
}
