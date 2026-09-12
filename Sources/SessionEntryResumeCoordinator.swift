import Foundation

/// Owns placement for every interactive Vault session action.
///
/// The launch value is prepared before placement, and the same immutable
/// snapshot is passed to the terminal topology owner that receives the startup
/// input. Resume creates an isolated workspace; Open creates an explicit split
/// in the selected local workspace; Focus only selects an already represented
/// surface. Keeping those mutations on one constructable coordinator prevents
/// the Vault row, popover, socket, and sidebar surfaces from growing divergent
/// launch paths.
@MainActor
struct SessionEntryResumeCoordinator {
    /// Creates a new workspace for a planned launch.
    ///
    /// Remote selections disable cwd inheritance so a remote path cannot become
    /// the local workspace's implicit starting directory.
    @discardableResult
    private func launchInNewWorkspace(
        _ launch: SessionEntryResumeLaunch,
        tabManager: TabManager
    ) -> Workspace? {
        let selected = tabManager.selectedWorkspace
        let isRemoteSelection = selected?.isRemoteWorkspace == true
            || selected?.isRemoteTmuxMirror == true
        return tabManager.addWorkspaceIfActive(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: launch.startupRestoreAgent,
            inheritWorkingDirectory: !isRemoteSelection
        )
    }

    /// Resumes `entry` in a new workspace, preserving its restore snapshot.
    ///
    /// - Returns: `true` when the workspace was created, otherwise `false`.
    @discardableResult
    func resume(_ entry: SessionEntry, tabManager: TabManager) -> Bool {
        guard let launch = entry.resumeLaunch else { return false }
        return launchInNewWorkspace(
            launch,
            tabManager: tabManager
        ) != nil
    }

    /// Returns the in-pane target for an indexed session, if one is currently
    /// running in a real surface in the tab manager.
    ///
    /// Keeping target discovery separate from focus mutation lets the Vault row
    /// expose an honest enabled/disabled state without mutating UI state while
    /// SwiftUI renders a context menu.
    func activeTarget(
        for entry: SessionEntry,
        tabManager: TabManager
    ) -> (workspaceID: UUID, surfaceID: UUID)? {
        for workspace in tabManager.tabs {
            if let panel = workspace.restoredAgentSnapshotsByPanelId.first(where: { panelID, snapshot in
                workspace.panels[panelID] != nil
                    && workspace.panelShellActivityStates[panelID] == .commandRunning
                    && snapshot.kind.rawValue == entry.agent.rawValue
                    && ManagedAgentSessionIdentity.sessionIDsMatch(
                        kind: entry.agent.rawValue,
                        lhs: snapshot.sessionId,
                        rhs: entry.sessionId
                    )
            }) {
                return (workspace.id, panel.key)
            }
        }

        // Process-detected sessions can still be present in the live index
        // before their snapshot has been projected into the tab manager.
        guard let index = SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh(),
              let match = index.forkValidationEntries().first(where: { panelKey, observation in
                  observation.processLiveness == .running
                      && observation.snapshot.kind.rawValue == entry.agent.rawValue
                      && ManagedAgentSessionIdentity.sessionIDsMatch(
                          kind: entry.agent.rawValue,
                          lhs: observation.snapshot.sessionId,
                          rhs: entry.sessionId
                      )
                      && tabManager.tabs.contains(where: { $0.id == panelKey.workspaceId })
                      && tabManager.tabs.first(where: { $0.id == panelKey.workspaceId })?.panels[panelKey.panelId] != nil
              }) else {
            return nil
        }

        return (match.0.workspaceId, match.0.panelId)
    }

    /// Returns managed-session identities whose commands are running in real panes.
    func inPaneSessionKeys(tabManager: TabManager) -> Set<String> {
        var keys: Set<String> = []
        for workspace in tabManager.tabs {
            for (panelID, snapshot) in workspace.restoredAgentSnapshotsByPanelId
                where workspace.panels[panelID] != nil
                    && workspace.panelShellActivityStates[panelID] == .commandRunning {
                keys.insert(
                    VaultLiveSessionKeys.key(
                        kind: snapshot.kind.rawValue,
                        sessionID: snapshot.sessionId
                    )
                )
            }
        }
        return keys
    }

    /// Opens an indexed session in a new split in the selected local workspace.
    ///
    /// Remote and remote-tmux selections fall back to the same isolated
    /// workspace path as ``resume(_:tabManager:)`` because a local restore
    /// selector cannot execute in a projected remote shell.
    @discardableResult
    func open(_ entry: SessionEntry, tabManager: TabManager) -> Bool {
        guard let launch = entry.resumeLaunch else { return false }
        guard let workspace = tabManager.selectedWorkspace,
              !workspace.isRemoteWorkspace,
              !workspace.isRemoteTmuxMirror,
              let paneId = workspace.bonsplitController.focusedPaneId
                  ?? workspace.bonsplitController.allPaneIds.first else {
            return launchInNewWorkspace(
                launch,
                tabManager: tabManager
            ) != nil
        }

        workspace.clearSplitZoom()
        if workspace.splitPaneWithNewTerminal(
            targetPane: paneId,
            orientation: .horizontal,
            insertFirst: false,
            workingDirectory: launch.workingDirectory,
            initialInput: launch.initialInput,
            startupRestoreAgent: launch.startupRestoreAgent
        ) != nil {
            return true
        }

        return launchInNewWorkspace(
            launch,
            tabManager: tabManager
        ) != nil
    }

    /// Focuses the current surface for `entry` without launching a duplicate.
    ///
    /// - Returns: `true` when an active matching surface was selected.
    @discardableResult
    func focusIfActive(_ entry: SessionEntry, tabManager: TabManager) -> Bool {
        guard let target = activeTarget(for: entry, tabManager: tabManager) else {
            return false
        }
        tabManager.focusTab(target.workspaceID, surfaceId: target.surfaceID)
        return true
    }
}
