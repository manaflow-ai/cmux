import Foundation

extension AgentHibernationRecord {
    /// Whether the indexed process set is complete enough to terminate safely.
    var hasPressureSafeProcessEvidence: Bool {
        hasLiveProcess &&
            !containsUnrelatedProcess &&
            !processIDs.isEmpty &&
            processIDs.count <= AgentHibernationController.maximumScopedProcessTerminationCount &&
            processIdentities.count == processIDs.count
    }

    /// Reclaim may terminate a live process only with complete scope evidence.
    var processSafetyAllowsHibernation: Bool {
        !hasLiveProcess || hasPressureSafeProcessEvidence
    }
}

extension RestorableAgentSessionIndex.Entry {
    /// Whether a fresh index still proves a safe scheduled process scope.
    var processSafetyAllowsScheduledHibernation: Bool {
        processIDs.isEmpty ||
            (
                !containsUnrelatedProcess &&
                    !terminationProcessIDs.isEmpty &&
                    terminationProcessIDs.count <= AgentHibernationController.maximumScopedProcessTerminationCount &&
                    terminationProcessIdentities.count == terminationProcessIDs.count
            )
    }
}

extension AppDelegate {
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
                    let processEntry = index.entry(
                        workspaceId: workspace.id,
                        panelId: panelId
                    )
                    let panelProcessIDs = processEntry?.processIDs ?? []
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
                            hasLiveProcess: !panelProcessIDs.isEmpty,
                            containsUnrelatedProcess: processEntry?.containsUnrelatedProcess ?? false,
                            panelProcessIDs: processEntry?.hibernationPanelProcessIDs ?? [],
                            processIDs: processEntry?.terminationProcessIDs ?? [],
                            processIdentities: processEntry?.terminationProcessIdentities ?? [:]
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
