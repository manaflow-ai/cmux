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

            let snapshot = index.snapshot(workspaceId: workspaceId, panelId: panelId)
                ?? currentContext.workspace.restoredAgentSnapshotsByPanelId[panelId]
                ?? commandPaletteForkableAgentSnapshotsByPanelKey[panelKey]
            guard let snapshot else {
                NSSound.beep()
                return
            }
            guard await AgentForkSupport.supportsFork(snapshot: snapshot) else {
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
                guard let startupInput = snapshot.forkStartupInput() else {
                    NSSound.beep()
                    return
                }
                let workingDirectory = currentContext.workspace.forkAgentWorkingDirectory(
                    fromPanelId: panelId,
                    snapshot: snapshot
                )
                _ = tabManager.addWorkspace(
                    workingDirectory: workingDirectory,
                    initialTerminalInput: startupInput,
                    autoWelcomeIfNeeded: false
                )
                didFork = true
            }

            guard didFork else {
                NSSound.beep()
                return
            }
        }
    }
}

private enum AgentConversationForkDestination: Sendable {
    case split(SplitDirection)
    case newWorkspace
}
