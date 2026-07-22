import Bonsplit
import Foundation

extension Workspace {
    /// Executes one validated fork request after the caller resolves the source snapshot.
    func forkAgentConversation(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        request: AgentConversationForkRequest,
        anchorTabId: TabID,
        paneId: PaneID
    ) -> Bool {
        let startupInputOverride = request.startupInputOverride(sourceSnapshot: snapshot)

        if let direction = request.destination.splitDirection {
            return forkAgentConversation(
                fromPanelId: panelId,
                snapshot: snapshot,
                direction: direction,
                startupInputOverride: startupInputOverride
            ) != nil
        }

        switch request.destination {
        case .newTab:
            return forkAgentConversationToNewTab(
                fromPanelId: panelId,
                snapshot: snapshot,
                anchorTabId: anchorTabId,
                paneId: paneId,
                startupInputOverride: startupInputOverride
            ) != nil
        case .newWorkspace:
            guard let owningTabManager,
                  let launch = forkAgentWorkspaceLaunch(
                      fromPanelId: panelId,
                      snapshot: snapshot,
                      startupInputOverride: startupInputOverride
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
        case .right, .left, .top, .bottom:
            return false
        }
    }
}
