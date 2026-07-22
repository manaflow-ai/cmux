import Bonsplit
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
              var anchorTabId = surfaceIdFromPanelId(panelId),
              var paneId = paneId(forPanelId: panelId) else {
            return false
        }
        let isRemoteContext = isRemoteTerminalSurface(panelId)
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
                  let refreshedAnchorTabId = surfaceIdFromPanelId(panelId),
                  let refreshedPaneId = self.paneId(forPanelId: panelId) else {
                return false
            }
            selection = refreshedSelection
            snapshot = refreshedSnapshot
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
            fromPanelId: panelId,
            snapshot: snapshot,
            destination: destination,
            anchorTabId: anchorTabId,
            paneId: paneId
        )
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
