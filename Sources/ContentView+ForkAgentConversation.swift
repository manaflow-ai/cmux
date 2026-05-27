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

        guard let currentContext = focusedPanelContext,
              currentContext.workspace.id == workspaceId,
              currentContext.panelId == panelId,
              currentContext.panel.panelType == .terminal else {
            NSSound.beep()
            return
        }

        let fallbackSnapshot = currentContext.workspace.restoredAgentSnapshotsByPanelId[panelId]
        let isRemoteContext = currentContext.workspace.isRemoteTerminalSurface(panelId)
        let snapshot = Self.commandPaletteImmediateForkExecutionSnapshot(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: isRemoteContext,
            supportedPanelKeys: commandPaletteForkableAgentSupportedPanelKeys,
            supportedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: commandPaletteForkableAgentSnapshotFingerprintsByPanelKey,
            fallbackSnapshot: fallbackSnapshot,
            cachedSnapshot: commandPaletteForkableAgentSnapshotsByPanelKey[panelKey]
        )
        guard let snapshot else {
            commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
            commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
            NSSound.beep()
            return
        }

        let fallbackFingerprint = fallbackSnapshot.map(Self.commandPaletteForkSnapshotFingerprint)
        commandPaletteForkableAgentSupportedPanelKeys.insert(panelKey)
        commandPaletteForkableAgentSnapshotsByPanelKey[panelKey] = snapshot
        commandPaletteForkableAgentSnapshotFingerprintsByPanelKey[panelKey] = Self.commandPaletteForkCacheFingerprint(
            snapshot: snapshot,
            fallbackFingerprint: fallbackFingerprint
        )
        commandPaletteForkableAgentRemoteContextsByPanelKey[panelKey] = isRemoteContext

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
            didFork = true
        }

        guard didFork else {
            NSSound.beep()
            return
        }
    }
}

extension ContentView {
    static func commandPaletteForkExecutionSnapshot(
        indexSnapshot: SessionRestorableAgentSnapshot?,
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        cachedSnapshot: SessionRestorableAgentSnapshot?
    ) -> SessionRestorableAgentSnapshot? {
        indexSnapshot ?? fallbackSnapshot ?? cachedSnapshot
    }

    static func commandPaletteImmediateForkExecutionSnapshot(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteTerminal: Bool,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        cachedSnapshot: SessionRestorableAgentSnapshot?
    ) -> SessionRestorableAgentSnapshot? {
        let panelKey = commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )
        guard let snapshot = commandPaletteForkExecutionSnapshot(
            indexSnapshot: nil,
            fallbackSnapshot: fallbackSnapshot,
            cachedSnapshot: cachedSnapshot
        ) else {
            return nil
        }

        switch commandPaletteSnapshotForkAvailability(snapshot, isRemoteTerminal: isRemoteTerminal) {
        case .supportedWithoutProbe:
            return snapshot
        case .unsupported:
            return nil
        case .requiresProbe:
            guard supportedPanelKeys.contains(panelKey),
                  supportedRemoteContextsByPanelKey[panelKey] == isRemoteTerminal else {
                return nil
            }
            let expectedFingerprint = (fallbackSnapshot ?? cachedSnapshot).map(commandPaletteForkSnapshotFingerprint)
            guard let expectedFingerprint,
                  snapshotFingerprintsByPanelKey[panelKey] == expectedFingerprint else {
                return nil
            }
            return snapshot
        }
    }

    static func commandPaletteForkPostProbeContextStillMatches(
        expectedWorkspaceId: UUID,
        expectedPanelId: UUID,
        expectedIsRemoteContext: Bool,
        currentWorkspaceId: UUID,
        currentPanelId: UUID,
        currentPanelIsTerminal: Bool,
        currentIsRemoteContext: Bool
    ) -> Bool {
        currentWorkspaceId == expectedWorkspaceId
            && currentPanelId == expectedPanelId
            && currentPanelIsTerminal
            && currentIsRemoteContext == expectedIsRemoteContext
    }
}

private enum AgentConversationForkDestination: Sendable {
    case split(SplitDirection)
    case newWorkspace
}
