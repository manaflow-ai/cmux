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
        guard let currentContext = focusedPanelContext,
              currentContext.panel.panelType == .terminal else {
            NSSound.beep()
            return
        }

        let workspaceId = currentContext.workspace.id
        let panelId = currentContext.panelId
        let panelKey = Self.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )

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
        func verifiedCachedSnapshot(expectedFingerprint: String?) -> SessionRestorableAgentSnapshot? {
            guard let cachedSnapshot,
                  supportedPanelKeys.contains(panelKey),
                  supportedRemoteContextsByPanelKey[panelKey] == isRemoteTerminal else {
                return nil
            }
            if let expectedFingerprint,
               snapshotFingerprintsByPanelKey[panelKey] != expectedFingerprint {
                return nil
            }
            guard commandPaletteSnapshotForkAvailability(
                cachedSnapshot,
                isRemoteTerminal: isRemoteTerminal
            ) != .unsupported else {
                return nil
            }
            return cachedSnapshot
        }

        if let fallbackSnapshot {
            let fallbackFingerprint = commandPaletteForkSnapshotFingerprint(fallbackSnapshot)
            switch commandPaletteSnapshotForkAvailability(
                fallbackSnapshot,
                isRemoteTerminal: isRemoteTerminal
            ) {
            case .supportedWithoutProbe:
                return verifiedCachedSnapshot(expectedFingerprint: fallbackFingerprint) ?? fallbackSnapshot
            case .unsupported:
                return nil
            case .requiresProbe:
                guard commandPaletteForkableAgentProbeResultMatches(
                    panelKey: panelKey,
                    supportedPanelKeys: supportedPanelKeys,
                    supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
                    snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
                    expectedSnapshotFingerprint: fallbackFingerprint,
                    isRemoteTerminal: isRemoteTerminal
                ) else {
                    return nil
                }
                return verifiedCachedSnapshot(expectedFingerprint: fallbackFingerprint) ?? fallbackSnapshot
            }
        }

        guard let cachedSnapshot = verifiedCachedSnapshot(expectedFingerprint: nil) else {
            return nil
        }
        switch commandPaletteSnapshotForkAvailability(
            cachedSnapshot,
            isRemoteTerminal: isRemoteTerminal
        ) {
        case .supportedWithoutProbe, .requiresProbe:
            return cachedSnapshot
        case .unsupported:
            return nil
        }
    }
}

private enum AgentConversationForkDestination: Sendable {
    case split(SplitDirection)
    case newWorkspace
}
