import Foundation

struct AgentHibernationPlannerInput: Sendable {
    let key: AgentHibernationPanelKey
    let hasRestorableAgent: Bool
    let isLive: Bool
    let hasLiveProcess: Bool
    let isProtected: Bool
    let lifecycle: AgentHibernationLifecycleState
    let isTemporarilyUnableToProtect: Bool
    let hasUnconfirmedTerminalInput: Bool
    let lastActivityAt: TimeInterval

    init(
        key: AgentHibernationPanelKey,
        hasRestorableAgent: Bool,
        isLive: Bool,
        hasLiveProcess: Bool = false,
        isProtected: Bool,
        lifecycle: AgentHibernationLifecycleState,
        isTemporarilyUnableToProtect: Bool = false,
        hasUnconfirmedTerminalInput: Bool,
        lastActivityAt: TimeInterval
    ) {
        self.key = key
        self.hasRestorableAgent = hasRestorableAgent
        self.isLive = isLive
        self.hasLiveProcess = hasLiveProcess
        self.isProtected = isProtected
        self.lifecycle = lifecycle
        self.isTemporarilyUnableToProtect = isTemporarilyUnableToProtect
        self.hasUnconfirmedTerminalInput = hasUnconfirmedTerminalInput
        self.lastActivityAt = lastActivityAt
    }
}

enum AgentHibernationPlanner {
    static func selectedPanelKeys(
        inputs: [AgentHibernationPlannerInput],
        settings: AgentHibernationSettings.Values,
        now: TimeInterval
    ) -> Set<AgentHibernationPanelKey> {
        guard settings.enabled else { return [] }
        let liveRestorable = inputs.filter { $0.hasRestorableAgent && $0.isLive }
        let excess = liveRestorable.count - settings.maxLiveTerminals
        guard excess > 0 else { return [] }

        // Live scoped processes still create cap pressure, but they are not
        // eligible for teardown; reclaim safe idle panes first instead.
        let eligible = liveRestorable
            .filter { input in
                !input.isProtected &&
                    !input.hasLiveProcess &&
                    input.lifecycle.allowsHibernation &&
                    !input.isTemporarilyUnableToProtect &&
                    !input.hasUnconfirmedTerminalInput &&
                    now - input.lastActivityAt >= settings.idleSeconds
            }
            .sorted { lhs, rhs in
                if lhs.lastActivityAt == rhs.lastActivityAt {
                    return lhs.key.panelId.uuidString < rhs.key.panelId.uuidString
                }
                return lhs.lastActivityAt < rhs.lastActivityAt
            }

        return Set(eligible.prefix(excess).map(\.key))
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
                            hasLiveProcess: index.hasLiveProcess(workspaceId: workspace.id, panelId: panelId),
                            processIDs: index.processIDs(workspaceId: workspace.id, panelId: panelId)
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
