import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxPanes
import Foundation

extension ContentView {
    func forkFocusedAgentConversationRight() {
        forkFocusedAgentConversation(.right)
    }

    func forkFocusedAgentConversationLeft() {
        forkFocusedAgentConversation(.left)
    }

    func forkFocusedAgentConversationTop() {
        forkFocusedAgentConversation(.top)
    }

    func forkFocusedAgentConversationBottom() {
        forkFocusedAgentConversation(.bottom)
    }

    func forkFocusedAgentConversationToNewTab() {
        forkFocusedAgentConversation(.newTab)
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
        let selection = Self.commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: isRemoteContext,
            supportedPanelKeys: commandPaletteForkableAgentProbeCoordinator.supportedPanelKeys,
            supportedRemoteContextsByPanelKey: commandPaletteForkableAgentProbeCoordinator.remoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: commandPaletteForkableAgentProbeCoordinator.snapshotFingerprintsByPanelKey,
            fallbackSnapshot: fallbackSnapshot,
            cachedSnapshot: commandPaletteForkableAgentProbeCoordinator.snapshotsByPanelKey[panelKey]
        )
        guard let selection else {
            clearCommandPaletteForkableAgentCache(panelKey: panelKey)
            NSSound.beep()
            return
        }
        let snapshot = selection.snapshot

        let fallbackFingerprint = fallbackSnapshot.map(Self.commandPaletteForkSnapshotFingerprint)
        commandPaletteForkableAgentProbeCoordinator.supportedPanelKeys.insert(panelKey)
        commandPaletteForkableAgentProbeCoordinator.snapshotsByPanelKey[panelKey] = snapshot
        commandPaletteForkableAgentProbeCoordinator.snapshotFingerprintsByPanelKey[panelKey] = Self.commandPaletteForkCacheFingerprint(
            snapshot: snapshot,
            fallbackFingerprint: fallbackFingerprint
        )
        commandPaletteForkableAgentProbeCoordinator.remoteContextsByPanelKey[panelKey] = isRemoteContext
        commandPaletteForkableAgentProbeCoordinator.resultHadFallbackByPanelKey[panelKey] = selection.usedFallbackSnapshot

        let didFork: Bool
        if let direction = destination.splitDirection {
            didFork = currentContext.workspace.forkAgentConversation(
                fromPanelId: panelId,
                snapshot: snapshot,
                direction: direction
            ) != nil
        } else {
            switch destination {
            case .newTab:
                guard let anchorTabId = currentContext.workspace.surfaceIdFromPanelId(panelId),
                      let paneId = currentContext.workspace.paneId(forPanelId: panelId) else {
                    clearCommandPaletteForkableAgentCache(panelKey: panelKey)
                    NSSound.beep()
                    return
                }
                didFork = currentContext.workspace.forkAgentConversationToNewTab(
                    fromPanelId: panelId,
                    snapshot: snapshot,
                    anchorTabId: anchorTabId,
                    paneId: paneId
                ) != nil
            case .newWorkspace:
                guard let launch = currentContext.workspace.forkAgentWorkspaceLaunch(
                    fromPanelId: panelId,
                    snapshot: snapshot
                ) else {
                    clearCommandPaletteForkableAgentCache(panelKey: panelKey)
                    NSSound.beep()
                    return
                }
                let forkWorkspace = tabManager.addWorkspace(
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
                didFork = true
            case .right, .left, .top, .bottom:
                didFork = false
            }
        }

        guard didFork else {
            clearCommandPaletteForkableAgentCache(panelKey: panelKey)
            NSSound.beep()
            return
        }
    }

    private func clearCommandPaletteForkableAgentCache(panelKey: String) {
        commandPaletteForkableAgentProbeCoordinator.supportedPanelKeys.remove(panelKey)
        commandPaletteForkableAgentProbeCoordinator.snapshotsByPanelKey.removeValue(forKey: panelKey)
        commandPaletteForkableAgentProbeCoordinator.snapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
        commandPaletteForkableAgentProbeCoordinator.remoteContextsByPanelKey.removeValue(forKey: panelKey)
        commandPaletteForkableAgentProbeCoordinator.resultHadFallbackByPanelKey.removeValue(forKey: panelKey)
    }
}

extension ContentView {
    struct CommandPaletteForkSnapshotSelection {
        let snapshot: SessionRestorableAgentSnapshot
        let usedFallbackSnapshot: Bool
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
        commandPaletteImmediateForkExecutionSnapshotSelection(
            workspaceId: workspaceId,
            panelId: panelId,
            isRemoteTerminal: isRemoteTerminal,
            supportedPanelKeys: supportedPanelKeys,
            supportedRemoteContextsByPanelKey: supportedRemoteContextsByPanelKey,
            snapshotFingerprintsByPanelKey: snapshotFingerprintsByPanelKey,
            fallbackSnapshot: fallbackSnapshot,
            cachedSnapshot: cachedSnapshot
        )?.snapshot
    }

    static func commandPaletteImmediateForkExecutionSnapshotSelection(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteTerminal: Bool,
        supportedPanelKeys: Set<String>,
        supportedRemoteContextsByPanelKey: [String: Bool],
        snapshotFingerprintsByPanelKey: [String: String],
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        cachedSnapshot: SessionRestorableAgentSnapshot?
    ) -> CommandPaletteForkSnapshotSelection? {
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
                if let cachedSnapshot = verifiedCachedSnapshot(expectedFingerprint: fallbackFingerprint) {
                    return CommandPaletteForkSnapshotSelection(
                        snapshot: cachedSnapshot,
                        usedFallbackSnapshot: false
                    )
                }
                return CommandPaletteForkSnapshotSelection(
                    snapshot: fallbackSnapshot,
                    usedFallbackSnapshot: true
                )
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
                if let cachedSnapshot = verifiedCachedSnapshot(expectedFingerprint: fallbackFingerprint) {
                    return CommandPaletteForkSnapshotSelection(
                        snapshot: cachedSnapshot,
                        usedFallbackSnapshot: false
                    )
                }
                return CommandPaletteForkSnapshotSelection(
                    snapshot: fallbackSnapshot,
                    usedFallbackSnapshot: true
                )
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
            return CommandPaletteForkSnapshotSelection(
                snapshot: cachedSnapshot,
                usedFallbackSnapshot: false
            )
        case .unsupported:
            return nil
        }
    }
}

// `AgentConversationForkDestination` and its configured-default reader now live
// in `CMUXAgentLaunch` (the `AgentForkCoordinator` `Destination` vocabulary). The
// localized display titles stay app-side here because `String(localized:)` must
// resolve against the app bundle, not the package bundle.
extension AgentConversationForkDestination {
    var title: String {
        switch self {
        case .right:
            return String(localized: "command.forkAgentConversationRight.title", defaultValue: "Fork Conversation to the Right")
        case .left:
            return String(localized: "command.forkAgentConversationLeft.title", defaultValue: "Fork Conversation to the Left")
        case .top:
            return String(localized: "command.forkAgentConversationTop.title", defaultValue: "Fork Conversation to the Top")
        case .bottom:
            return String(localized: "command.forkAgentConversationBottom.title", defaultValue: "Fork Conversation to the Bottom")
        case .newTab:
            return String(localized: "command.forkAgentConversationNewTab.title", defaultValue: "Fork Conversation to New Tab")
        case .newWorkspace:
            return String(localized: "command.forkAgentConversationNewWorkspace.title", defaultValue: "Fork Conversation to New Workspace")
        }
    }

    var settingsTitle: String {
        switch self {
        case .right:
            return String(localized: "forkConversation.destination.right", defaultValue: "Right Split")
        case .left:
            return String(localized: "forkConversation.destination.left", defaultValue: "Left Split")
        case .top:
            return String(localized: "forkConversation.destination.top", defaultValue: "Top Split")
        case .bottom:
            return String(localized: "forkConversation.destination.bottom", defaultValue: "Bottom Split")
        case .newTab:
            return String(localized: "forkConversation.destination.newTab", defaultValue: "New Tab")
        case .newWorkspace:
            return String(localized: "forkConversation.destination.newWorkspace", defaultValue: "New Workspace")
        }
    }

    var settingsDescription: String {
        switch self {
        case .right:
            return String(localized: "forkConversation.destination.right.description", defaultValue: "Right-click Fork Conversation creates a split to the right.")
        case .left:
            return String(localized: "forkConversation.destination.left.description", defaultValue: "Right-click Fork Conversation creates a split to the left.")
        case .top:
            return String(localized: "forkConversation.destination.top.description", defaultValue: "Right-click Fork Conversation creates a split above the current pane.")
        case .bottom:
            return String(localized: "forkConversation.destination.bottom.description", defaultValue: "Right-click Fork Conversation creates a split below the current pane.")
        case .newTab:
            return String(localized: "forkConversation.destination.newTab.description", defaultValue: "Right-click Fork Conversation creates a sibling tab in the current pane.")
        case .newWorkspace:
            return String(localized: "forkConversation.destination.newWorkspace.description", defaultValue: "Right-click Fork Conversation creates a new workspace.")
        }
    }
}
