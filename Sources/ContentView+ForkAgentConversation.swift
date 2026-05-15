import AppKit
import Foundation

extension ContentView {
    func forkFocusedAgentConversationRight() {
        forkFocusedAgentConversation(.split(.right))
    }

    func forkFocusedAgentConversationLeft() {
        forkFocusedAgentConversation(.split(.left))
    }

    func forkFocusedAgentConversationTop() {
        forkFocusedAgentConversation(.split(.up))
    }

    func forkFocusedAgentConversationBottom() {
        forkFocusedAgentConversation(.split(.down))
    }

    func forkFocusedAgentConversationToNewWorkspace() {
        forkFocusedAgentConversation(.newWorkspace)
    }

    private func forkFocusedAgentConversation(_ destination: AgentConversationForkDestination) {
        guard let initialContext = focusedPanelContext,
              initialContext.panel.panelType == .terminal else {
            NSSound.beep()
            return
        }

        let workspaceId = initialContext.workspace.id
        let panelId = initialContext.panelId
        let panelKey = Self.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )

        Task { @MainActor in
            let index = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots()
            guard let currentContext = focusedPanelContext,
                  currentContext.workspace.id == workspaceId,
                  currentContext.panelId == panelId,
                  currentContext.panel.panelType == .terminal else {
                NSSound.beep()
                return
            }

            let snapshot = Self.commandPaletteForkExecutionSnapshot(
                indexSnapshot: index.snapshot(workspaceId: workspaceId, panelId: panelId),
                fallbackSnapshot: currentContext.workspace.restoredAgentSnapshotsByPanelId[panelId],
                cachedSnapshot: commandPaletteForkableAgentSnapshotsByPanelKey[panelKey]
            )
            guard let snapshot else {
                commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
                commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                NSSound.beep()
                return
            }
            let isRemoteContext = currentContext.workspace.isRemoteWorkspace ||
                currentContext.workspace.isRemoteTerminalSurface(panelId)
            guard await AgentForkSupport.supportsFork(
                snapshot: snapshot,
                isRemoteContext: isRemoteContext
            ) else {
                NSSound.beep()
                return
            }
            commandPaletteForkableAgentSupportedPanelKeys.insert(
                panelKey
            )
            commandPaletteForkableAgentSnapshotsByPanelKey[panelKey] = snapshot
            commandPaletteForkableAgentSnapshotFingerprintsByPanelKey[panelKey] = Self.commandPaletteForkSnapshotFingerprint(snapshot)

            let didFork: Bool
            switch destination {
            case .split(let direction):
                didFork = currentContext.workspace.forkAgentConversation(
                    fromPanelId: panelId,
                    snapshot: snapshot,
                    direction: direction
                ) != nil
            case .newWorkspace:
                guard let launch = currentContext.workspace.forkAgentWorkspaceLaunch(
                    fromPanelId: panelId,
                    snapshot: snapshot
                ) else {
                    NSSound.beep()
                    return
                }
                let forkWorkspace = tabManager.addWorkspace(
                    workingDirectory: launch.terminalWorkingDirectory,
                    initialTerminalCommand: launch.initialTerminalCommand,
                    initialTerminalInput: launch.initialTerminalInput,
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
                didFork = true
            }

            guard didFork else {
                NSSound.beep()
                return
            }
        }
    }
}

extension ContentView {
    static func commandPaletteForkExecutionSnapshot(
        indexSnapshot: SessionRestorableAgentSnapshot?,
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        cachedSnapshot _: SessionRestorableAgentSnapshot?
    ) -> SessionRestorableAgentSnapshot? {
        indexSnapshot ?? fallbackSnapshot
    }
}

private enum AgentConversationForkDestination: Sendable {
    case split(SplitDirection)
    case newWorkspace
}
