import AppKit
import CMUXAgentLaunch
import Foundation

@MainActor
struct SessionEntryResumeCoordinator {
    let tabManager: TabManager

    @discardableResult
    private func launchInNewWorkspace(
        _ launch: SessionEntryResumeLaunch
    ) -> Workspace? {
        tabManager.addWorkspaceIfActive(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: launch.startupRestoreAgent
        )
    }

    /// Returns the in-pane target for an indexed session, if one is currently
    /// represented by a real surface in the tab manager.
    ///
    /// Keeping target discovery separate from the focus mutation lets the Vault
    /// row expose an honest enabled/disabled state without focusing anything
    /// while SwiftUI is rendering a context menu.
    func activeTarget(
        for entry: SessionEntry
    ) -> (workspaceID: UUID, surfaceID: UUID)? {
        // Prefer the tab manager's authoritative surface snapshots. This
        // catches an open-but-idle session even while the process index is
        // between refreshes.
        for workspace in tabManager.tabs where entry.agent != .codex {
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
        guard let index = SharedLiveAgentIndex.shared.index,
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

    /// Returns the managed-session identities currently represented by real
    /// panes. This is a read-only presentation snapshot; it never focuses or
    /// selects a workspace and is safe to hand across the Vault row boundary.
    func inPaneSessionKeys() -> Set<String> {
        var keys: Set<String> = []
        for workspace in tabManager.tabs {
            for (panelID, snapshot) in workspace.restoredAgentSnapshotsByPanelId
                where workspace.panels[panelID] != nil && snapshot.kind.rawValue != "codex"
                    && workspace.panelShellActivityStates[panelID] == .commandRunning {
                keys.insert(
                    VaultLiveSessionKeys.key(
                        kind: snapshot.kind.rawValue,
                        sessionID: snapshot.sessionId
                    )
                )
            }
        }
        // Cached live evidence is presentation-only. The Focus mutation always
        // rechecks the actual lock and runtime; rendering performs no I/O.
        if let index = SharedLiveAgentIndex.shared.index {
            for (key, observation) in index.forkValidationEntries()
            where observation.snapshot.kind.rawValue == "codex" && observation.processLiveness == .running {
                guard !observation.processIDs.isEmpty,
                      tabManager.tabs.contains(where: {
                          $0.id == key.workspaceId && $0.panels[key.panelId] != nil
                              && $0.panelShellActivityStates[key.panelId] == .commandRunning
                      })
                else { continue }
                keys.insert(VaultLiveSessionKeys.key(kind: "codex", sessionID: observation.snapshot.sessionId))
            }
        }
        return keys
    }

    /// Opens an indexed session in a new split in the selected workspace.
    ///
    /// Open intentionally creates another split for other providers. Codex's
    /// single-writer contract instead continues an exactly mapped live owner.
    func open(_ entry: SessionEntry) async {
        let destination = tabManager.selectedWorkspace?.id
        guard !(await handleCodexWriterConflict(for: entry)),
              !Task.isCancelled, tabManager.selectedWorkspace?.id == destination else { return }
        guard let launch = entry.resumeLaunch else { return }

        guard let workspace = tabManager.selectedWorkspace,
              !workspace.isRemoteWorkspace,
              !workspace.isRemoteTmuxMirror,
              let paneId = workspace.bonsplitController.focusedPaneId
                  ?? workspace.bonsplitController.allPaneIds.first else {
            // A remote workspace cannot safely execute a local Vault restore
            // command. If there is no usable local pane, fall back to the
            // same isolated-workspace launch used by Resume.
            _ = launchInNewWorkspace(launch)
            return
        }

        // A zoomed pane has no room to represent the new split until it is
        // restored to the normal layout.
        workspace.clearSplitZoom()
        if workspace.splitPaneWithNewTerminal(
            targetPane: paneId,
            orientation: .horizontal,
            insertFirst: false,
            workingDirectory: launch.workingDirectory,
            initialInput: launch.initialInput,
            startupRestoreAgent: launch.startupRestoreAgent
        ) == nil {
            // Keep the action useful if the selected workspace retires between
            // menu presentation and invocation.
            _ = launchInNewWorkspace(launch)
        }
    }

    /// Focuses the current surface for `entry` when the live agent index still
    /// points at a real panel in this tab manager.
    @discardableResult
    func focusIfActive(_ entry: SessionEntry) async -> Bool {
        if entry.agent == .codex {
            return await handleCodexWriterConflict(for: entry)
        }
        guard let target = activeTarget(for: entry) else {
            return false
        }
        tabManager.focusTab(target.workspaceID, surfaceId: target.surfaceID)
        return true
    }

    func resume(_ entry: SessionEntry) async {
        guard !(await handleCodexWriterConflict(for: entry)), !Task.isCancelled else { return }
        guard let launch = entry.resumeLaunch else { return }
        // Resume is deliberately workspace-scoped. It must remain predictable
        // even when the selected workspace happens to share the session's cwd;
        // Open Session is the separate action for a split in the current
        // workspace.
        _ = launchInNewWorkspace(launch)
    }
}
