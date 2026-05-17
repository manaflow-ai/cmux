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
        let isInitialRemoteContext = initialContext.workspace.isRemoteTerminalSurface(panelId)
        let ttyName = Self.commandPaletteNormalizedTTYName(initialContext.workspace.surfaceTTYNames[panelId])
        let ttyWasReportedInCurrentSession = initialContext.workspace.hasCurrentSessionReportedTTY(forPanelId: panelId)
        let ttyCacheValue = Self.commandPaletteTTYCacheValue(ttyName)
        let panelKey = Self.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )

        Task { @MainActor in
            let index = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots(
                fallbackScope: Self.commandPaletteProcessDetectionFallbackScope(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    isRemoteTerminal: isInitialRemoteContext,
                    ttyWasReportedInCurrentSession: ttyWasReportedInCurrentSession,
                    ttyName: ttyName
                )
            )
            guard let currentContext = focusedPanelContext,
                  currentContext.workspace.id == workspaceId,
                  currentContext.panelId == panelId,
                  currentContext.panel.panelType == .terminal,
                  currentContext.workspace.hasCurrentSessionReportedTTY(forPanelId: panelId) == ttyWasReportedInCurrentSession,
                  Self.commandPaletteNormalizedTTYName(currentContext.workspace.surfaceTTYNames[panelId]) == ttyName else {
                NSSound.beep()
                return
            }
            let snapshot = Self.commandPaletteForkExecutionSnapshot(
                indexSnapshot: index.snapshot(workspaceId: workspaceId, panelId: panelId),
                fallbackSnapshot: currentContext.workspace.restoredAgentSnapshotsByPanelId[panelId]
            )
            guard let snapshot else {
                commandPaletteForkableAgentSupportedPanelKeys.remove(panelKey)
                commandPaletteForkableAgentSnapshotsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentRemoteContextsByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentTTYNamesByPanelKey.removeValue(forKey: panelKey)
                commandPaletteForkableAgentProbeCompletedAtByPanelKey.removeValue(forKey: panelKey)
                NSSound.beep()
                return
            }
            let isRemoteContext = currentContext.workspace.isRemoteTerminalSurface(panelId)
            guard await AgentForkSupport.supportsFork(
                snapshot: snapshot,
                isRemoteContext: isRemoteContext
            ) else {
                NSSound.beep()
                return
            }
            guard let postProbeContext = focusedPanelContext,
                  Self.commandPaletteForkPostProbeContextStillMatches(
                    expectedWorkspaceId: workspaceId,
                    expectedPanelId: panelId,
                    expectedIsRemoteContext: isRemoteContext,
                    expectedTTYName: ttyName,
                    currentWorkspaceId: postProbeContext.workspace.id,
                    currentPanelId: postProbeContext.panelId,
                    currentPanelIsTerminal: postProbeContext.panel.panelType == .terminal,
                    currentIsRemoteContext: postProbeContext.workspace.isRemoteTerminalSurface(panelId),
                    currentTTYName: postProbeContext.workspace.surfaceTTYNames[panelId]
                  ) else {
                NSSound.beep()
                return
            }
            commandPaletteForkableAgentSupportedPanelKeys.insert(
                panelKey
            )
            commandPaletteForkableAgentSnapshotsByPanelKey[panelKey] = snapshot
            commandPaletteForkableAgentSnapshotFingerprintsByPanelKey[panelKey] = Self.commandPaletteForkSnapshotFingerprint(snapshot)
            commandPaletteForkableAgentRemoteContextsByPanelKey[panelKey] = isRemoteContext
            commandPaletteForkableAgentTTYNamesByPanelKey[panelKey] = ttyCacheValue

            let didFork: Bool
            switch destination {
            case .split(let direction):
                didFork = postProbeContext.workspace.forkAgentConversation(
                    fromPanelId: panelId,
                    snapshot: snapshot,
                    direction: direction
                ) != nil
            case .newWorkspace:
                guard let launch = postProbeContext.workspace.forkAgentWorkspaceLaunch(
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
}

extension ContentView {
    static func commandPaletteForkExecutionSnapshot(
        indexSnapshot: SessionRestorableAgentSnapshot?,
        fallbackSnapshot: SessionRestorableAgentSnapshot?
    ) -> SessionRestorableAgentSnapshot? {
        indexSnapshot ?? fallbackSnapshot
    }

    static func commandPaletteForkPostProbeContextStillMatches(
        expectedWorkspaceId: UUID,
        expectedPanelId: UUID,
        expectedIsRemoteContext: Bool,
        expectedTTYName: String?,
        currentWorkspaceId: UUID,
        currentPanelId: UUID,
        currentPanelIsTerminal: Bool,
        currentIsRemoteContext: Bool,
        currentTTYName: String?
    ) -> Bool {
        currentWorkspaceId == expectedWorkspaceId
            && currentPanelId == expectedPanelId
            && currentPanelIsTerminal
            && currentIsRemoteContext == expectedIsRemoteContext
            && commandPaletteNormalizedTTYName(currentTTYName) == commandPaletteNormalizedTTYName(expectedTTYName)
    }

    static func commandPaletteProcessDetectionFallbackScope(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteTerminal: Bool,
        ttyWasReportedInCurrentSession: Bool,
        ttyName: String?
    ) -> RestorableAgentProcessDetectionScope? {
        guard !isRemoteTerminal else { return nil }
        guard ttyWasReportedInCurrentSession,
              let normalizedTTYName = commandPaletteNormalizedTTYName(ttyName) else {
            return nil
        }
        return RestorableAgentProcessDetectionScope(
            workspaceId: workspaceId,
            panelId: panelId,
            ttyName: normalizedTTYName
        )
    }
}

private enum AgentConversationForkDestination: Sendable {
    case split(SplitDirection)
    case newWorkspace
}
