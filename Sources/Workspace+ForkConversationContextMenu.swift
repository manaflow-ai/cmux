import Bonsplit
import CmuxCore
import CmuxSettings
import Foundation

extension Workspace {
    @discardableResult
    func forkAgentConversationFromContextMenu(
        fromPanelId panelId: UUID,
        destination: AgentConversationForkDestination
    ) async -> Bool {
        guard beginForkAgentConversationAction(panelId: panelId) else {
            return false
        }
        defer {
            endForkAgentConversationAction(panelId: panelId)
        }

        var selection = forkAgentConversationContextMenuOpenSelection(
            forPanelId: panelId
        )
        guard var snapshot = selection.snapshot,
              var ownership = surfaceOwnershipTarget(for: panelId),
              var anchorTabId = surfaceIdFromPanelId(ownership.containerPanelID),
              var paneId = paneId(forPanelId: ownership.containerPanelID) else {
            return false
        }
        let isRemoteContext = isRemoteTerminalContext(ownership.surfaceID)
        if AgentForkSupport.requiresForkValidationExecutableIdentity(
            snapshot: snapshot,
            isRemoteContext: isRemoteContext
        ) {
            let selectedSnapshotFingerprint = ContentView.commandPaletteForkSnapshotFingerprint(
                snapshot,
                isRemoteTerminal: isRemoteContext
            )
            let selectedValidationIdentity = AgentForkSupport.forkValidationIdentity(
                snapshot: snapshot,
                isRemoteContext: isRemoteContext
            )
            guard let cachedExecutableFingerprint = SharedLiveAgentIndex.shared.forkSupportProbeExecutableFingerprint(
                workspaceId: id,
                panelId: panelId,
                isRemoteContext: isRemoteContext,
                fallbackSnapshot: selection.validationFallbackSnapshot
            ) else {
                return false
            }
            let currentExecutableFingerprint = await SharedLiveAgentIndex.shared.forkValidationExecutableFingerprint(
                snapshot: snapshot,
                isRemoteContext: isRemoteContext
            )
            let refreshedSelection = forkAgentConversationContextMenuOpenSelection(
                forPanelId: panelId
            )
            guard refreshedSelection.availability.isAvailable,
                  let refreshedSnapshot = refreshedSelection.snapshot,
                  ContentView.commandPaletteForkSnapshotFingerprint(
                    refreshedSnapshot,
                    isRemoteTerminal: isRemoteContext
                  ) == selectedSnapshotFingerprint,
                  AgentForkSupport.forkValidationIdentity(
                    snapshot: refreshedSnapshot,
                    isRemoteContext: isRemoteContext
                  ) == selectedValidationIdentity,
                  let refreshedOwnership = surfaceOwnershipTarget(for: panelId),
                  isRemoteTerminalContext(refreshedOwnership.surfaceID)
                    == isRemoteContext,
                  let refreshedAnchorTabId = surfaceIdFromPanelId(
                    refreshedOwnership.containerPanelID
                  ),
                  let refreshedPaneId = self.paneId(
                    forPanelId: refreshedOwnership.containerPanelID
                  ) else {
                return false
            }
            selection = refreshedSelection
            snapshot = refreshedSnapshot
            ownership = refreshedOwnership
            anchorTabId = refreshedAnchorTabId
            paneId = refreshedPaneId
            guard currentExecutableFingerprint == cachedExecutableFingerprint,
                  SharedLiveAgentIndex.shared.forkSupportProbeAccepted(
                    workspaceId: id,
                    panelId: panelId,
                    isRemoteContext: isRemoteContext,
                    fallbackSnapshot: selection.validationFallbackSnapshot
                  ) else {
                return false
            }
        }

        return forkAgentConversation(
            mutationPanelId: ownership.containerPanelID,
            snapshot: snapshot,
            destination: destination,
            anchorTabId: anchorTabId,
            paneId: paneId,
            projectedPane: remoteTmuxControlPane(surfaceID: ownership.surfaceID)
        )
    }

    private func forkAgentConversation(
        mutationPanelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        destination: AgentConversationForkDestination,
        anchorTabId: TabID,
        paneId: PaneID,
        projectedPane: RemoteTmuxControlPaneLocation?
    ) -> Bool {
        if let projectedPane {
            return forkProjectedTmuxAgentConversation(
                projectedPane,
                snapshot: snapshot,
                destination: destination
            )
        }

        if let direction = destination.splitDirection {
            return forkAgentConversation(
                fromPanelId: mutationPanelId,
                snapshot: snapshot,
                direction: direction
            ) != nil
        }

        switch destination {
        case .newTab:
            return forkAgentConversationToNewTab(
                fromPanelId: mutationPanelId,
                snapshot: snapshot,
                anchorTabId: anchorTabId,
                paneId: paneId
            ) != nil
        case .newWorkspace:
            return forkAgentConversationToNewWorkspace(
                fromPanelId: mutationPanelId,
                snapshot: snapshot
            )
        case .right, .left, .top, .bottom:
            return false
        }
    }

    func forkProjectedTmuxAgentConversation(
        _ location: RemoteTmuxControlPaneLocation,
        snapshot: SessionRestorableAgentSnapshot,
        destination: AgentConversationForkDestination
    ) -> Bool {
        var launchSnapshot = snapshot
        let workingDirectory = Self.normalizedForkWorkingDirectory(
            snapshot.workingDirectory
                ?? remoteTmuxSessionMirror?.cwdByPane[location.pane.tmuxPaneID]
        )
        launchSnapshot.workingDirectory = workingDirectory
        guard let shellCommand = launchSnapshot.forkCommand,
              RemoteTmuxHost.controlModeLineSafeName(shellCommand) != nil else {
            return false
        }

        if let direction = destination.splitDirection {
            return location.requestAgentForkSplit(
                vertical: direction.orientation == .vertical,
                insertBefore: direction.insertFirst,
                shellCommand: shellCommand,
                workingDirectory: workingDirectory
            )
        }

        switch destination {
        case .newTab:
            return location.requestAgentForkNewWindow(
                shellCommand: shellCommand,
                workingDirectory: workingDirectory
            )
        case .newWorkspace:
            return forkProjectedTmuxAgentConversationToNewWorkspace(
                snapshot: launchSnapshot
            )
        case .right, .left, .top, .bottom:
            return false
        }
    }

    private func forkProjectedTmuxAgentConversationToNewWorkspace(
        snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        guard let owningTabManager,
              let host = remoteTmuxSessionMirror?.host,
              let startupInput = snapshot.forkStartupInput(
                allowLauncherScript: false,
                // Typed into the remote host's shell after attach: keep POSIX.
                dialect: .remoteHost
              ),
              let remoteConfiguration = SessionRemoteWorkspaceSnapshot(
                transport: .ssh,
                terminalTransport: .ssh,
                terminalProfile: .shell,
                destination: host.destination,
                port: host.port,
                identityFile: host.identityFile,
                sshOptions: host.sshControlArguments(
                    controlPersistSeconds: 180,
                    batchMode: false
                )
              ).workspaceConfiguration(
                localSocketPath: TerminalController.shared.currentSocketPathForRemoteRestore(),
                allowPersistentPTYRestore: false,
                preserveSSHOptions: true
              ) else {
            return false
        }

        guard let forkWorkspace = owningTabManager.addWorkspaceIfActive(
            workingDirectory: nil,
            initialTerminalCommand: remoteConfiguration.terminalStartupCommand,
            initialTerminalInput: startupInput,
            initialTerminalEnvironment: remoteConfiguration.sshTerminalStartupEnvironment ?? [:],
            inheritWorkingDirectory: false,
            autoWelcomeIfNeeded: false
        ) else {
            return false
        }
        forkWorkspace.configureRemoteConnection(
            remoteConfiguration,
            autoConnect: true
        )
        if let workingDirectory = snapshot.workingDirectory,
           let forkPanelID = forkWorkspace.focusedPanelId {
            forkWorkspace.updatePanelDirectory(
                panelId: forkPanelID,
                directory: workingDirectory
            )
        }
        return true
    }

    private static func normalizedForkWorkingDirectory(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              RemoteTmuxHost.controlModeLineSafeName(trimmed) != nil else {
            return nil
        }
        return trimmed
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

        guard let forkWorkspace = owningTabManager.addWorkspaceIfActive(
            workingDirectory: launch.terminalWorkingDirectory,
            initialTerminalCommand: launch.initialTerminalCommand,
            initialTerminalInput: launch.initialTerminalInput,
            initialTerminalEnvironment: launch.initialTerminalEnvironment,
            inheritWorkingDirectory: launch.terminalWorkingDirectory != nil,
            autoWelcomeIfNeeded: false
        ) else {
            return false
        }
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
