import Bonsplit
import CmuxSettings
import Foundation

extension Workspace {
    @discardableResult
    func forkAgentConversationFromContextMenu(
        fromPanelId panelId: UUID,
        destination: AgentConversationForkDestination
    ) -> Bool {
        guard forkAgentConversationContextMenuAvailability(forPanelId: panelId).isAvailable,
              let snapshot = forkableAgentSnapshot(forPanelId: panelId),
              let anchorTabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else {
            return false
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
