import Foundation

extension TabManager {
    /// Saves one live workspace to the parked manifest and tears down its runtime resources.
    @discardableResult
    func parkWorkspaceNonInteractively(_ workspace: Workspace) -> Bool {
        guard tabs.contains(where: { $0.id == workspace.id }),
              canCloseWorkspace(workspace, allowPinned: true),
              let index = tabs.firstIndex(where: { $0.id == workspace.id }) else {
            return false
        }

        let snapshot = workspace.sessionSnapshot(
            includeScrollback: true,
            restorableAgentIndex: SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
                ?? RestorableAgentSessionIndex.load()
        )
        // A TabManager keeps one live workspace while its window is open. Seed a
        // replacement shell before parking the final workspace so the action is
        // available on every workspace without leaving the app window empty.
        let replacementWorkspace: Workspace?
        if tabs.count == 1 {
            guard let replacement = addWorkspaceIfActive(
                select: true,
                eagerLoadTerminal: true,
                autoWelcomeIfNeeded: false
            ) else {
                return false
            }
            replacementWorkspace = replacement
        } else {
            replacementWorkspace = nil
        }
        let record = ParkedWorkspaceRecord(
            id: workspace.id,
            workspaceIndex: index,
            windowId: AppDelegate.shared?.windowId(for: self),
            snapshot: snapshot
        )
        guard ParkedWorkspaceStore.shared.append(record),
              ParkedWorkspaceStore.shared.flush() else {
            _ = ParkedWorkspaceStore.shared.remove(id: record.id)
            if let replacementWorkspace {
                closeWorkspace(replacementWorkspace, recordHistory: false)
            }
            return false
        }
        closeWorkspace(workspace, recordHistory: false)
        return !tabs.contains(where: { $0.id == workspace.id })
    }

    /// Restores a parked workspace through the same identity and topology path as close history.
    @discardableResult
    func unparkWorkspace(_ record: ParkedWorkspaceRecord) -> Bool {
        let entry = ClosedWorkspaceHistoryEntry(
            workspaceId: record.id,
            windowId: record.windowId,
            workspaceIndex: record.workspaceIndex,
            snapshot: record.snapshot
        )
        if restoreClosedWorkspace(entry) {
            _ = ParkedWorkspaceStore.shared.remove(id: record.id)
            return true
        }

        // A removed transcript or incompatible resume command must leave the
        // workspace usable with its captured terminal history as context. Drop
        // only the agent launch metadata and keep the topology, titles, and
        // scrollback so the user can start a fresh session explicitly.
        var fallbackSnapshot = record.snapshot
        var hadAgentResume = false
        fallbackSnapshot.panels = fallbackSnapshot.panels.map { panel in
            var panel = panel
            guard var terminal = panel.terminal else { return panel }
            guard terminal.agent != nil || terminal.resumeBinding != nil || terminal.managedAgentResumeBinding != nil else {
                return panel
            }
            hadAgentResume = true
            terminal.agent = nil
            terminal.resumeBinding = nil
            terminal.managedAgentResumeBinding = nil
            terminal.wasAgentRunning = nil
            panel.terminal = terminal
            return panel
        }
        guard hadAgentResume else { return false }
        let fallbackState: AgentRestoreRecoveryPresentation.State = fallbackSnapshot.panels.contains {
            $0.terminal?.scrollback?.isEmpty == false
        } ? .parkedResumeUnavailable : .parkedTranscriptUnavailable
        let fallbackEntry = ClosedWorkspaceHistoryEntry(
            workspaceId: record.id,
            windowId: record.windowId,
            workspaceIndex: record.workspaceIndex,
            snapshot: fallbackSnapshot
        )
        guard restoreClosedWorkspace(fallbackEntry) else { return false }
        if let workspace = tabs.first(where: { $0.id == record.id }) {
            for panel in workspace.panels.values {
                (panel as? TerminalPanel)?.restoreRecovery.state = fallbackState
            }
        }
        _ = ParkedWorkspaceStore.shared.remove(id: record.id)
        return true
    }

    /// Closes a socket/API-targeted workspace without an interactive veto.
    ///
    /// Closing a window's last workspace means closing the window. A remote-tmux
    /// mirror is detached from its local owner first so a socket close never maps
    /// to the explicit remote-session kill path.
    @discardableResult
    func closeWorkspaceNonInteractively(
        _ workspace: Workspace,
        recordHistory: Bool = true,
        allowPinned: Bool = false
    ) -> Bool {
        guard canCloseWorkspace(workspace, allowPinned: allowPinned),
              tabs.contains(where: { $0.id == workspace.id }) else { return false }
        guard tabs.count == 1 else {
            closeWorkspace(workspace, recordHistory: recordHistory)
            return !tabs.contains(where: { $0.id == workspace.id })
        }
        guard let appDelegate = AppDelegate.shared,
              let windowId = appDelegate.windowId(for: self) else { return false }
        if workspace.isRemoteTmuxMirror {
            appDelegate.remoteTmuxController.detachMirrorWorkspaceKeptOpenLocally(workspaceId: workspace.id)
        }
        guard appDelegate.closeMainWindow(windowId: windowId, recordHistory: recordHistory) else {
            return false
        }
        return true
    }
}
