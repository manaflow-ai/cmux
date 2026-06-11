import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Agent conversation forking
extension Workspace {
    struct AgentConversationForkWorkspaceLaunch: Equatable {
        var workingDirectory: String?
        var terminalWorkingDirectory: String?
        var initialTerminalCommand: String?
        var initialTerminalInput: String
        var initialTerminalEnvironment: [String: String]
        var remoteConfiguration: WorkspaceRemoteConfiguration?
        var autoConnectRemoteConfiguration: Bool
    }

    func forkAgentWorkspaceLaunch(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> AgentConversationForkWorkspaceLaunch? {
        var launchSnapshot = snapshot
        let workingDirectory = forkAgentWorkingDirectory(fromPanelId: panelId, snapshot: snapshot)
        launchSnapshot.workingDirectory = workingDirectory
        let remoteStartupCommand = forkAgentRemoteStartupCommand(fromPanelId: panelId)
        let remoteConfiguration = forkAgentRemoteConfigurationForNewWorkspace(fromPanelId: panelId)
        let isRemoteFork = remoteConfiguration?.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard panels[panelId] is TerminalPanel,
              let startupInput = launchSnapshot.forkStartupInput(
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  allowLauncherScript: !isRemoteFork
              ) else {
            return nil
        }

        return AgentConversationForkWorkspaceLaunch(
            workingDirectory: workingDirectory,
            terminalWorkingDirectory: isRemoteFork ? nil : workingDirectory,
            initialTerminalCommand: remoteConfiguration?.terminalStartupCommand ?? remoteStartupCommand,
            initialTerminalInput: startupInput,
            initialTerminalEnvironment: isRemoteFork ? (remoteConfiguration?.sshTerminalStartupEnvironment ?? [:]) : [:],
            remoteConfiguration: remoteConfiguration,
            autoConnectRemoteConfiguration: remoteConfiguration != nil
        )
    }

    @discardableResult
    func forkAgentConversation(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        direction: SplitDirection,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> TerminalPanel? {
        var launchSnapshot = snapshot
        let workingDirectory = forkAgentWorkingDirectory(fromPanelId: panelId, snapshot: snapshot)
        launchSnapshot.workingDirectory = workingDirectory
        let remoteStartupCommand = forkAgentRemoteStartupCommand(fromPanelId: panelId)
        guard panels[panelId] is TerminalPanel,
              let paneId = paneId(forPanelId: panelId),
              let startupInput = launchSnapshot.forkStartupInput(
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  allowLauncherScript: remoteStartupCommand == nil
              ) else {
            return nil
        }

        let zoomedPaneId = bonsplitController.zoomedPaneId
        if zoomedPaneId != nil {
            clearSplitZoom()
        }
        let forkedPanel = splitPaneWithNewTerminal(
            targetPane: paneId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            workingDirectory: remoteStartupCommand == nil ? workingDirectory : nil,
            initialInput: startupInput,
            remoteStartupCommand: remoteStartupCommand
        )
        if let forkedPanel,
           remoteStartupCommand != nil,
           let workingDirectory {
            updatePanelDirectory(panelId: forkedPanel.id, directory: workingDirectory)
        }
        if forkedPanel == nil, let zoomedPaneId {
            _ = bonsplitController.togglePaneZoom(inPane: zoomedPaneId)
        }
        return forkedPanel
    }

    func forkAgentWorkingDirectory(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot
    ) -> String? {
        Self.firstNonEmptyPath([
            snapshot.workingDirectory,
            panelDirectories[panelId],
            terminalPanel(for: panelId)?.requestedWorkingDirectory,
            currentDirectory
        ])
    }

    /// Synchronous availability check used by the tab right-click context menu to decide
    /// whether to surface the Fork Conversation item for a given anchor tab. Restricted to
    /// `.supportedWithoutProbe` so we never offer an item that may quietly fail; agents
    /// requiring a probe (e.g. shell-launched OpenCode) stay reachable from the command
    /// palette path that performs that probe first.
    func canForkAgentConversationFromPanel(_ panelId: UUID) -> Bool {
        guard panels[panelId] is TerminalPanel else { return false }
        guard let snapshot = forkableAgentSnapshot(forPanelId: panelId) else {
            return false
        }
        let isRemote = isRemoteTerminalSurface(panelId)
        return ContentView.commandPaletteSnapshotForkAvailability(
            snapshot,
            isRemoteTerminal: isRemote
        ) == .supportedWithoutProbe
    }

    /// Snapshot used by the right-click fork path. Prefers the workspace's restored snapshot
    /// (filled on session restore / hibernation), then falls back to the process-wide
    /// `SharedLiveAgentIndex`. The shared index loads the on-disk hook session store off the
    /// main actor (it runs `sysctl(KERN_PROCARGS2)` per live record for live-PID filtering,
    /// which is too expensive to do synchronously during SwiftUI menu evaluation) and a
    /// single load serves every workspace. The Workspace subscribes to the shared store's
    /// `indexDidChange` in its initializer so that when a refresh lands, this workspace's
    /// tracked `sharedAgentIndexRevision` bumps, `WorkspaceContentView` re-renders, and
    /// bonsplit's TabBarView re-evaluates the menu state on the same frame — Fork
    /// Conversation appears the moment the index is loaded without requiring a second
    /// right-click.
    func forkableAgentSnapshot(forPanelId panelId: UUID) -> SessionRestorableAgentSnapshot? {
        if let snapshot = restoredAgentSnapshotsByPanelId[panelId] {
            return snapshot
        }
        return SharedLiveAgentIndex.shared.snapshot(workspaceId: id, panelId: panelId)
    }

    /// Fork the panel's agent conversation into a brand-new sibling tab placed immediately
    /// to the right of `anchorTabId` in `paneId`. Uses the same `claude --resume --fork-session`
    /// startup input the existing split/new-workspace forks rely on, so divergence is owned by
    /// the agent itself (Claude / Codex / OpenCode) instead of any cmux-side history copy.
    @discardableResult
    func forkAgentConversationToNewTab(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        anchorTabId: TabID,
        paneId: PaneID,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> TerminalPanel? {
        var launchSnapshot = snapshot
        let workingDirectory = forkAgentWorkingDirectory(fromPanelId: panelId, snapshot: snapshot)
        launchSnapshot.workingDirectory = workingDirectory
        let remoteStartupCommand = forkAgentRemoteStartupCommand(fromPanelId: panelId)
        guard panels[panelId] is TerminalPanel,
              let startupInput = launchSnapshot.forkStartupInput(
                  fileManager: fileManager,
                  temporaryDirectory: temporaryDirectory,
                  allowLauncherScript: remoteStartupCommand == nil
              ) else {
            return nil
        }

        let zoomedPaneId = bonsplitController.zoomedPaneId
        if zoomedPaneId != nil {
            clearSplitZoom()
        }

        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        let forkedPanel = newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: remoteStartupCommand == nil ? workingDirectory : nil,
            initialInput: startupInput
        )
        if let forkedPanel {
            _ = reorderSurface(panelId: forkedPanel.id, toIndex: targetIndex)
            if remoteStartupCommand != nil, let workingDirectory {
                updatePanelDirectory(panelId: forkedPanel.id, directory: workingDirectory)
            }
        } else if let zoomedPaneId {
            _ = bonsplitController.togglePaneZoom(inPane: zoomedPaneId)
        }
        return forkedPanel
    }

    private func forkAgentRemoteStartupCommand(fromPanelId panelId: UUID) -> String? {
        guard isRemoteTerminalSurface(panelId) else { return nil }
        return remoteTerminalStartupCommand()
    }

    private func forkAgentRemoteConfigurationForNewWorkspace(fromPanelId panelId: UUID) -> WorkspaceRemoteConfiguration? {
        guard forkAgentRemoteStartupCommand(fromPanelId: panelId) != nil else { return nil }
        let forkedSSHOptions = remoteConfiguration
            .map { WorkspaceRemoteConfiguration.forkedAgentSSHOptions($0.sshOptions) }
        return remoteConfiguration?.sessionSnapshot(sshOptionsOverride: forkedSSHOptions)?.workspaceConfiguration(
            localSocketPath: TerminalController.shared.currentSocketPathForRemoteRestore(),
            allowPersistentPTYRestore: false,
            preserveSSHOptions: true,
            agentSocketPath: remoteConfiguration?.agentSocketPath
        ) ?? remoteConfiguration
    }

    private static func firstNonEmptyPath(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    func handleForkConversationContextAction(_ action: TabContextAction, for tab: Bonsplit.Tab, inPane pane: PaneID) {
        guard let panelId = panelIdFromSurfaceId(tab.id),
              let snapshot = forkableAgentSnapshot(forPanelId: panelId) else {
            NSSound.beep()
            return
        }
        // Mirror the menu-visibility gate exactly: only fork when the snapshot is
        // probe-free supported. Using the weaker `!= .unsupported` here would let a
        // `.requiresProbe` snapshot through if the action is ever wired up outside
        // the bonsplit menu, leading to a fork that may quietly fail at the shell.
        let isRemote = isRemoteTerminalSurface(panelId)
        guard ContentView.commandPaletteSnapshotForkAvailability(
            snapshot,
            isRemoteTerminal: isRemote
        ) == .supportedWithoutProbe else {
            NSSound.beep()
            return
        }

        let destination = action == .forkConversation
            ? AgentConversationForkDefaultSettings.current()
            : AgentConversationForkDestination(tabContextAction: action)
        guard forkAgentConversation(
            fromPanelId: panelId,
            snapshot: snapshot,
            destination: destination,
            anchorTabId: tab.id,
            paneId: pane
        ) else {
            NSSound.beep()
            return
        }
    }

    private func forkAgentConversation(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        destination: AgentConversationForkDestination,
        anchorTabId: TabID,
        paneId: PaneID
    ) -> Bool {
        if let direction = destination.splitDirection {
            return forkAgentConversation(
                fromPanelId: panelId,
                snapshot: snapshot,
                direction: direction
            ) != nil
        }

        switch destination {
        case .newTab:
            return forkAgentConversationToNewTab(
                fromPanelId: panelId,
                snapshot: snapshot,
                anchorTabId: anchorTabId,
                paneId: paneId
            ) != nil
        case .newWorkspace:
            return forkAgentConversationToNewWorkspace(
                fromPanelId: panelId,
                snapshot: snapshot
            )
        case .right, .left, .top, .bottom:
            return false
        }
    }

    private func forkAgentConversationToNewWorkspace(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        guard let owningTabManager,
              let launch = forkAgentWorkspaceLaunch(
                  fromPanelId: panelId,
                  snapshot: snapshot
              ) else {
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

}
