import CMUXAgentLaunch
import CmuxCore
import CmuxPanes
import Bonsplit
import Foundation
import AppKit

/// `Workspace` is the live host for its `AgentForkCoordinator`. The coordinator
/// (in `CMUXAgentLaunch`) owns the agent-conversation *fork* orchestration: the
/// guard ordering, the local-vs-remote-fork branch, the new-workspace launch
/// descriptor assembly, the zoom save/restore around a split, and the
/// destination dispatch. Everything those bodies touch on the live window is
/// irreducibly app-coupled, so each member here reproduces one read or mutation
/// the legacy inline fork bodies performed on `self`: the live panel set and
/// remote-terminal classification, the resolved fork working directory and
/// startup input, the remote startup command and forked-workspace remote
/// configuration, the actual split / new-tab / new-workspace terminal creation,
/// the post-create directory application and zoom restoration, the menu fork-
/// availability gate, the snapshot lookup (restored, then the shared live-agent
/// index), and the failure beep. The coordinator is held by `Workspace` and
/// references this host weakly, so there is no retain cycle.
///
/// This mirrors the sibling `Workspace+AgentHibernationHosting.swift` pattern:
/// the lifted coordinator's live seam conformance lives in its own app-target
/// file so `Workspace.swift` drains the orchestration instead of trading it for
/// inline seam glue.
extension Workspace: AgentForkHosting {
    // The `AgentForkHosting` associated types (`Snapshot`, `TerminalSurface`,
    // `PaneIdentifier`, `TabIdentifier`, `Direction`, `Destination`) are inferred
    // from the method witnesses below. They are NOT spelled as explicit
    // `typealias` members here on purpose: a `typealias TerminalSurface =
    // TerminalPanel` on `Workspace` would shadow the global `TerminalSurface`
    // class for every `TerminalSurface(...)` reference inside `Workspace`'s own
    // methods.

    // MARK: - Panel classification

    func agentForkPanelIsTerminal(_ panelId: UUID) -> Bool {
        panels[panelId] is TerminalPanel
    }

    // MARK: - Working directory / startup input

    func agentForkWorkingDirectory(
        panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot
    ) -> String? {
        Self.firstNonEmptyPath([
            snapshot.workingDirectory,
            panelDirectories[panelId],
            terminalPanel(for: panelId)?.requestedWorkingDirectory,
            currentDirectory
        ])
    }

    func agentForkStartupInput(
        snapshot: SessionRestorableAgentSnapshot,
        workingDirectory: String?,
        allowLauncherScript: Bool
    ) -> String? {
        var launchSnapshot = snapshot
        launchSnapshot.workingDirectory = workingDirectory
        return launchSnapshot.forkStartupInput(allowLauncherScript: allowLauncherScript)
    }

    // MARK: - Remote fork resolution

    func agentForkRemoteStartupCommand(panelId: UUID) -> String? {
        guard isRemoteTerminalSurface(panelId) else { return nil }
        return remoteTerminalStartupCommand()
    }

    func agentForkRemoteConfigurationForNewWorkspace(
        panelId: UUID
    ) -> WorkspaceRemoteConfiguration? {
        guard agentForkRemoteStartupCommand(panelId: panelId) != nil else { return nil }
        let forkedSSHOptions = remoteConfiguration
            .map { WorkspaceRemoteConfiguration.forkedAgentSSHOptions($0.sshOptions) }
        return remoteConfiguration?.sessionSnapshot(sshOptionsOverride: forkedSSHOptions)?.workspaceConfiguration(
            localSocketPath: TerminalController.shared.currentSocketPathForRemoteRestore(),
            allowPersistentPTYRestore: false,
            preserveSSHOptions: true,
            agentSocketPath: remoteConfiguration?.agentSocketPath
        ) ?? remoteConfiguration
    }

    // MARK: - Snapshot lookup

    func agentForkableSnapshot(panelId: UUID) -> SessionRestorableAgentSnapshot? {
        if let snapshot = restoredAgentSnapshotsByPanelId[panelId] {
            return snapshot
        }
        if let snapshot = SharedLiveAgentIndex.shared.snapshot(workspaceId: id, panelId: panelId) {
            return snapshot
        }
        // Last resort: a live agent cmux never recorded a hook for (e.g. an
        // `sr claude` / direct `codex` launch that bypassed the cmux wrapper).
        // Lazily process-detected and debounced, off the hot hook-store path.
        return SharedLiveAgentIndex.shared.processDetectedSnapshot(workspaceId: id, panelId: panelId)
    }

    func agentForkSnapshotIsSupportedWithoutProbe(
        snapshot: SessionRestorableAgentSnapshot,
        panelId: UUID
    ) -> Bool {
        let isRemote = isRemoteTerminalSurface(panelId)
        return ContentView.commandPaletteSnapshotForkAvailability(
            snapshot,
            isRemoteTerminal: isRemote
        ) == .supportedWithoutProbe
    }

    // MARK: - Split / new-tab / new-workspace creation

    func agentForkSaveAndClearSplitZoom() -> PaneID? {
        let zoomedPaneId = bonsplitController.zoomedPaneId
        if zoomedPaneId != nil {
            clearSplitZoom()
        }
        return zoomedPaneId
    }

    func agentForkRestoreSplitZoom(_ paneId: PaneID) {
        _ = bonsplitController.togglePaneZoom(inPane: paneId)
    }

    func agentForkPaneId(forPanelId panelId: UUID) -> PaneID? {
        paneId(forPanelId: panelId)
    }

    func agentForkSplitPaneWithNewTerminal(
        targetPane: PaneID,
        direction: SplitDirection,
        workingDirectory: String?,
        initialInput: String,
        remoteStartupCommand: String?
    ) -> TerminalPanel? {
        splitPaneWithNewTerminal(
            targetPane: targetPane,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            workingDirectory: workingDirectory,
            initialInput: initialInput,
            remoteStartupCommand: remoteStartupCommand
        )
    }

    func agentForkNewTabSurface(
        anchorTabId: TabID,
        paneId: PaneID,
        workingDirectory: String?,
        initialInput: String
    ) -> TerminalPanel? {
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        let forkedPanel = newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: workingDirectory,
            initialInput: initialInput
        )
        if let forkedPanel {
            reorderSurface(panelId: forkedPanel.id, toIndex: targetIndex)
        }
        return forkedPanel
    }

    func agentForkApplyDirectory(to surface: TerminalPanel, directory: String) {
        updatePanelDirectory(panelId: surface.id, directory: directory)
    }

    func agentForkOpenNewWorkspace(launch: AgentConversationForkWorkspaceLaunch) -> Bool {
        guard let owningTabManager else {
            return false
        }

        let forkWorkspace = owningTabManager.addWorkspace(
            workingDirectory: launch.terminalWorkingDirectory,
            initialTerminalCommand: launch.initialTerminalCommand,
            initialTerminalInput: launch.initialTerminalInput,
            initialTerminalEnvironment: launch.initialTerminalEnvironment,
            inheritWorkingDirectory: launch.terminalWorkingDirectory != nil,
            autoWelcomeIfNeeded: false
        )
        if let remoteConfiguration = launch.remoteConfiguration {
            forkWorkspace.configureRemoteConnection(
                remoteConfiguration,
                autoConnect: launch.autoConnectRemoteConfiguration
            )
        }
        if let workingDirectory = launch.workingDirectory,
           launch.terminalWorkingDirectory == nil,
           let forkPanelId = forkWorkspace.focusedPanelId {
            forkWorkspace.updatePanelDirectory(panelId: forkPanelId, directory: workingDirectory)
        }
        return true
    }

    // MARK: - Destination dispatch

    func agentForkSplitDirection(for destination: AgentConversationForkDestination) -> SplitDirection? {
        destination.splitDirection
    }

    func agentForkDestinationIsNewTab(_ destination: AgentConversationForkDestination) -> Bool {
        destination == .newTab
    }

    func agentForkDestinationIsNewWorkspace(_ destination: AgentConversationForkDestination) -> Bool {
        destination == .newWorkspace
    }

    func agentForkBeep() {
        NSSound.beep()
    }
}
