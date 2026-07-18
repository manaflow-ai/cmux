import Foundation

extension AppDelegate {
    @MainActor
    func agentHibernationOpenTerminalPanelKeys(
        maximumCount: Int
    ) -> Set<RestorableAgentSessionIndex.PanelKey>? {
        guard maximumCount >= 0 else { return nil }
        var panelKeys = Set<RestorableAgentSessionIndex.PanelKey>()
        var seenManagers = Set<ObjectIdentifier>()

        func visit(tabManager manager: TabManager) -> Bool {
            guard seenManagers.insert(ObjectIdentifier(manager)).inserted else { return true }
            for workspace in manager.tabs {
                for (panelID, panel) in workspace.panels where panel is TerminalPanel {
                    panelKeys.insert(.init(workspaceId: workspace.id, panelId: panelID))
                    guard panelKeys.count <= maximumCount else { return false }
                }
            }
            return true
        }

        for context in mainWindowContexts.values {
            guard visit(tabManager: context.tabManager) else { return nil }
        }
        if let tabManager, !visit(tabManager: tabManager) { return nil }
        return panelKeys
    }

    @MainActor
    func agentHibernationPanelIsProtected(workspace: Workspace, panelId: UUID) -> Bool {
        for context in mainWindowContexts.values {
            guard context.window?.isVisible == true,
                  context.tabManager.selectedTabId == workspace.id else {
                continue
            }
            if workspace.agentHibernationVisiblePanelIdsForCurrentLayout().contains(panelId) {
                return true
            }
        }
        return false
    }

    @MainActor
    func agentHibernationRecords(
        index: RestorableAgentSessionIndex,
        activityByPanel: [AgentHibernationPanelKey: TimeInterval],
        terminalInputByPanel: [AgentHibernationPanelKey: TimeInterval],
        lifecycleChangeByPanel: [AgentHibernationPanelKey: TimeInterval]
    ) -> [AgentHibernationRecord] {
        var records: [AgentHibernationRecord] = []
        var seenManagers: Set<ObjectIdentifier> = []

        func visit(tabManager manager: TabManager, visibleWorkspaceId: UUID?) {
            let managerId = ObjectIdentifier(manager)
            guard seenManagers.insert(managerId).inserted else { return }
            for workspace in manager.tabs {
                let workspaceIsVisible = visibleWorkspaceId == workspace.id
                let visiblePanelIds = workspaceIsVisible
                    ? workspace.agentHibernationVisiblePanelIdsForCurrentLayout()
                    : []
                for (panelId, panel) in workspace.panels {
                    guard let terminalPanel = panel as? TerminalPanel,
                          let agent = workspace.restorableAgentForHibernation(panelId: panelId, index: index) else {
                        continue
                    }
                    let key = AgentHibernationPanelKey(workspaceId: workspace.id, panelId: panelId)
                    let indexActivity = index.updatedAt(workspaceId: workspace.id, panelId: panelId) ?? 0
                    let localActivity = activityByPanel[key] ?? 0
                    let terminalInputAt = terminalInputByPanel[key] ?? 0
                    let lifecycleChangeAt = lifecycleChangeByPanel[key] ?? 0
                    let createdAt = terminalPanel.surface.debugRuntimeSurfaceCreatedAt()?.timeIntervalSince1970
                        ?? terminalPanel.surface.debugCreatedAt().timeIntervalSince1970
                    let lifecycle = workspace.agentHibernationLifecycleState(
                        panelId: panelId,
                        fallback: index.lifecycle(workspaceId: workspace.id, panelId: panelId)
                    )
                    let indexedEvidence = index.processEvidence(
                        workspaceId: workspace.id,
                        panelId: panelId
                    )
                    let processEvidence: AgentHibernationProcessEvidence
                    if case .confirmedProcessFree(let lease) = indexedEvidence,
                       lease.workspaceId == workspace.id,
                       lease.panelId == panelId,
                       workspace.surfaceTTYDevices[panelId] == lease.ttyDevice,
                       !workspace.isRemoteWorkspace,
                       !workspace.isRemoteTerminalSurface(panelId),
                       AgentHibernationController.passesPromptAndCloseGates(
                           workspaceShellActivity: workspace.panelShellActivityStates[panelId],
                           panelShellActivity: terminalPanel.shellActivity.state,
                           rawNeedsConfirmClose: terminalPanel.needsConfirmClose(),
                           workspaceNeedsConfirmClose: workspace.panelNeedsConfirmClose(panelId: panelId)
                       ) {
                        processEvidence = indexedEvidence
                    } else {
                        processEvidence = .unverified(
                            processIDs: indexedEvidence.processIDs.union(
                                index.processIDs(workspaceId: workspace.id, panelId: panelId)
                            )
                        )
                    }
                    records.append(
                        AgentHibernationRecord(
                            key: key,
                            workspace: workspace,
                            terminalPanel: terminalPanel,
                            agent: agent,
                            lifecycle: lifecycle,
                            hasUnconfirmedTerminalInput: terminalInputAt > lifecycleChangeAt,
                            lastActivityAt: max(indexActivity, localActivity, createdAt),
                            isProtected: workspaceIsVisible && visiblePanelIds.contains(panelId),
                            processEvidence: processEvidence
                        )
                    )
                }
            }
        }

        for context in mainWindowContexts.values {
            let visibleWorkspaceId = context.window?.isVisible == true ? context.tabManager.selectedTabId : nil
            visit(tabManager: context.tabManager, visibleWorkspaceId: visibleWorkspaceId)
        }
        if let tabManager {
            visit(tabManager: tabManager, visibleWorkspaceId: nil)
        }

        return records
    }
}
