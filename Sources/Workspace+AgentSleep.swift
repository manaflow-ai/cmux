import Foundation

/// User-initiated Sleep for agent panels.
///
/// Sleep is manual entry into the existing Agent Hibernation teardown: it frees
/// the agent process now, regardless of the routine idle/limit policy, and the
/// panel stays asleep until the user explicitly wakes it. Every entrypoint
/// (panel context menu, sidebar workspace row) funnels through the methods here
/// so selection, eligibility, and wake behavior have one implementation.
extension Workspace {
    /// Panels this workspace can put to sleep right now.
    ///
    /// A panel qualifies when it is a terminal with a tracked agent process and
    /// is not already asleep. Plain shells are excluded: they have no resume
    /// identity, so waking one could only mean a fresh shell with the scrollback
    /// gone, which is not what a reversible-sounding "Sleep" should do.
    func sleepableAgentPanelIds() -> [UUID] {
        // Remote workspaces run their agents on the far side of the transport,
        // where this teardown path has no process to reclaim.
        guard !isRemoteWorkspace else { return [] }
        return panels.keys
            .filter { canSleepAgentPanel(panelId: $0) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    func canSleepAgentPanel(panelId: UUID) -> Bool {
        guard !isRemoteWorkspace,
              let terminalPanel = panels[panelId] as? TerminalPanel,
              !terminalPanel.isAgentHibernated,
              !terminalPanel.isAgentHibernationCommitPending else {
            return false
        }
        return !(agentPIDKeysByPanelId[panelId] ?? []).isEmpty
    }

    /// True when any of `panelIds` holds an agent that is mid-turn or waiting on
    /// the user. Callers use this to confirm before sleeping, since tearing down
    /// here interrupts work in progress rather than reclaiming an idle process.
    func agentSleepNeedsConfirmation(panelIds: [UUID]) -> Bool {
        panelIds.contains { panelId in
            let lifecycle = agentHibernationLifecycleState(panelId: panelId, fallback: nil)
            return lifecycle == .running || lifecycle == .needsInput
        }
    }

    @discardableResult
    func sleepAgentPanel(panelId: UUID) -> Bool {
        guard canSleepAgentPanel(panelId: panelId) else { return false }
        return AgentHibernationController.shared.sleepPanels(
            keys: [AgentHibernationPanelKey(workspaceId: id, panelId: panelId)]
        )
    }

    /// Sleeps every eligible agent panel in this workspace in one request, so
    /// the controller tears them down as a single batch.
    @discardableResult
    func sleepWorkspaceAgents() -> Bool {
        let panelIds = sleepableAgentPanelIds()
        guard !panelIds.isEmpty else { return false }
        let keys = Set(
            panelIds.map { AgentHibernationPanelKey(workspaceId: id, panelId: $0) }
        )
        return AgentHibernationController.shared.sleepPanels(keys: keys)
    }

    /// Panels currently asleep by user request. Drives Wake menu visibility.
    func manuallySleptPanelIds() -> [UUID] {
        panels.keys
            .filter { (panels[$0] as? TerminalPanel)?.isManuallySlept == true }
            .sorted { $0.uuidString < $1.uuidString }
    }

    @discardableResult
    func wakeAgentPanel(panelId: UUID, focus: Bool = true) -> Bool {
        resumeAgentHibernation(panelId: panelId, focus: focus)
    }

    @discardableResult
    func wakeWorkspaceAgents() -> Bool {
        var didWake = false
        for panelId in manuallySleptPanelIds() {
            didWake = wakeAgentPanel(panelId: panelId, focus: false) || didWake
        }
        return didWake
    }
}
