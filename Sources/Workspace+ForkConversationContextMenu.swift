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
        await forkAgentConversationFromContextMenu(
            fromPanelId: panelId,
            request: .sameHarness(destination: destination)
        )
    }

    @discardableResult
    func forkAgentConversationFromContextMenu(
        fromPanelId panelId: UUID,
        request: AgentConversationForkRequest
    ) async -> Bool {
        guard beginForkAgentConversationAction(panelId: panelId) else {
            return false
        }
        defer {
            endForkAgentConversationAction(panelId: panelId)
        }

        guard var selection = agentConversationForkSelection(
            forPanelId: panelId,
            request: request
        ),
              var ownership = surfaceOwnershipTarget(for: panelId) else {
            return false
        }
        var snapshot = selection.snapshot
        let isRemoteContext = isRemoteTerminalContext(ownership.surfaceID)
        if selection.requiresNativeForkCapability,
           AgentForkSupport.requiresForkValidationExecutableIdentity(
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
            guard let refreshedSelection = agentConversationForkSelection(
                forPanelId: panelId,
                request: request
            ) else {
                return false
            }
            guard refreshedSelection.requiresNativeForkCapability,
                  ContentView.commandPaletteForkSnapshotFingerprint(
                      refreshedSelection.snapshot,
                      isRemoteTerminal: isRemoteContext
                  ) == selectedSnapshotFingerprint,
                  AgentForkSupport.forkValidationIdentity(
                      snapshot: refreshedSelection.snapshot,
                      isRemoteContext: isRemoteContext
                  ) == selectedValidationIdentity,
                  let refreshedOwnership = surfaceOwnershipTarget(for: panelId),
                  isRemoteTerminalContext(refreshedOwnership.surfaceID)
                    == isRemoteContext else {
                return false
            }
            selection = refreshedSelection
            snapshot = refreshedSelection.snapshot
            ownership = refreshedOwnership
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

        return await forkAgentConversation(
            from: ownership,
            snapshot: snapshot,
            request: request
        )
    }

    func forkAgentConversation(
        from ownership: WorkspaceSurfaceOwnershipTarget,
        snapshot: SessionRestorableAgentSnapshot,
        request: AgentConversationForkRequest
    ) async -> Bool {
        if let projectedPane = remoteTmuxControlPane(surfaceID: ownership.surfaceID) {
            guard request.targetHarness.usesNativeFork(for: snapshot.kind) else {
                return false
            }
            return forkProjectedTmuxAgentConversation(
                projectedPane,
                snapshot: snapshot,
                destination: request.destination
            )
        }

        return await forkAgentConversation(
            fromPanelId: ownership.containerPanelID,
            snapshot: snapshot,
            request: request
        )
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
                allowLauncherScript: false
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

        let forkWorkspace = owningTabManager.addWorkspace(
            workingDirectory: nil,
            initialTerminalCommand: remoteConfiguration.terminalStartupCommand,
            initialTerminalInput: startupInput,
            initialTerminalEnvironment: remoteConfiguration.sshTerminalStartupEnvironment ?? [:],
            inheritWorkingDirectory: false,
            autoWelcomeIfNeeded: false
        )
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

}
