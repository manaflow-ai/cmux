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
        let panelKey = Self.commandPaletteForkableAgentPanelKey(
            workspaceId: workspaceId,
            panelId: panelId
        )

        Task { @MainActor in
            var index = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots(
                fallbackScope: Self.commandPaletteProcessDetectionFallbackScope(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    isRemoteTerminal: isInitialRemoteContext,
                    ttyWasReportedInCurrentSession: ttyWasReportedInCurrentSession,
                    ttyName: ttyName
                )
            )
            guard var currentContext = focusedPanelContext,
                  currentContext.workspace.id == workspaceId,
                  currentContext.panelId == panelId,
                  currentContext.panel.panelType == .terminal,
                  currentContext.workspace.isRemoteTerminalSurface(panelId) == isInitialRemoteContext else {
                NSSound.beep()
                return
            }

            var effectiveTTYName = Self.commandPaletteNormalizedTTYName(currentContext.workspace.surfaceTTYNames[panelId])
            var effectiveTTYWasReportedInCurrentSession = currentContext.workspace.hasCurrentSessionReportedTTY(forPanelId: panelId)
            if effectiveTTYName != ttyName ||
                effectiveTTYWasReportedInCurrentSession != ttyWasReportedInCurrentSession {
                index = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots(
                    fallbackScope: Self.commandPaletteProcessDetectionFallbackScope(
                        workspaceId: workspaceId,
                        panelId: panelId,
                        isRemoteTerminal: isInitialRemoteContext,
                        ttyWasReportedInCurrentSession: effectiveTTYWasReportedInCurrentSession,
                        ttyName: effectiveTTYName
                    )
                )
                guard let refreshedContext = focusedPanelContext,
                      refreshedContext.workspace.id == workspaceId,
                      refreshedContext.panelId == panelId,
                      refreshedContext.panel.panelType == .terminal,
                      refreshedContext.workspace.isRemoteTerminalSurface(panelId) == isInitialRemoteContext else {
                    NSSound.beep()
                    return
                }
                currentContext = refreshedContext
                effectiveTTYName = Self.commandPaletteNormalizedTTYName(refreshedContext.workspace.surfaceTTYNames[panelId])
                effectiveTTYWasReportedInCurrentSession = refreshedContext.workspace.hasCurrentSessionReportedTTY(forPanelId: panelId)
            }

            let ttyCacheValue = Self.commandPaletteTTYCacheValue(effectiveTTYName)
            let cachedSnapshot = Self.commandPaletteForkCachedSnapshot(
                panelKey: panelKey,
                cachedSnapshot: commandPaletteForkableAgentSnapshotsByPanelKey[panelKey],
                cachedRemoteContextsByPanelKey: commandPaletteForkableAgentRemoteContextsByPanelKey,
                cachedTTYNamesByPanelKey: commandPaletteForkableAgentTTYNamesByPanelKey,
                cachedTTYFreshByPanelKey: commandPaletteForkableAgentTTYFreshByPanelKey,
                isRemoteTerminal: isInitialRemoteContext,
                ttyName: effectiveTTYName,
                ttyWasReportedInCurrentSession: effectiveTTYWasReportedInCurrentSession
            )
            let snapshot = Self.commandPaletteForkExecutionSnapshot(
                indexSnapshot: index.snapshot(workspaceId: workspaceId, panelId: panelId),
                fallbackSnapshot: currentContext.workspace.restoredAgentSnapshotsByPanelId[panelId],
                cachedSnapshot: cachedSnapshot
            )
            guard let snapshot else {
                clearCommandPaletteForkableAgentCache(for: panelKey)
                NSSound.beep()
                return
            }
            let isRemoteContext = isInitialRemoteContext
            guard await AgentForkSupport.supportsFork(
                snapshot: snapshot,
                isRemoteContext: isRemoteContext
            ) else {
                clearCommandPaletteForkableAgentCache(for: panelKey)
                NSSound.beep()
                return
            }
            guard let postProbeContext = focusedPanelContext,
                  Self.commandPaletteForkPostProbeTTYStillMatches(
                    expectedTTYWasReportedInCurrentSession: effectiveTTYWasReportedInCurrentSession,
                    currentTTYWasReportedInCurrentSession: postProbeContext.workspace.hasCurrentSessionReportedTTY(forPanelId: panelId),
                    expectedTTYName: effectiveTTYName,
                    currentTTYName: postProbeContext.workspace.surfaceTTYNames[panelId]
                  ),
                  Self.commandPaletteForkPostProbeContextStillMatches(
                    expectedWorkspaceId: workspaceId,
                    expectedPanelId: panelId,
                    expectedIsRemoteContext: isRemoteContext,
                    expectedTTYName: effectiveTTYName,
                    currentWorkspaceId: postProbeContext.workspace.id,
                    currentPanelId: postProbeContext.panelId,
                    currentPanelIsTerminal: postProbeContext.panel.panelType == .terminal,
                    currentIsRemoteContext: postProbeContext.workspace.isRemoteTerminalSurface(panelId),
                    currentTTYName: postProbeContext.workspace.surfaceTTYNames[panelId]
                  ) else {
                clearCommandPaletteForkableAgentCache(for: panelKey)
                NSSound.beep()
                return
            }
            commandPaletteForkableAgentSupportedPanelKeys.insert(
                panelKey
            )
            commandPaletteForkableAgentSnapshotsByPanelKey[panelKey] = snapshot
            commandPaletteForkableAgentSnapshotFingerprintsByPanelKey[panelKey] = Self.commandPaletteForkSnapshotFingerprint(snapshot)
            commandPaletteForkableAgentUnsupportedSnapshotFingerprintsByPanelKey.removeValue(forKey: panelKey)
            commandPaletteForkableAgentRemoteContextsByPanelKey[panelKey] = isRemoteContext
            commandPaletteForkableAgentTTYNamesByPanelKey[panelKey] = ttyCacheValue
            commandPaletteForkableAgentTTYFreshByPanelKey[panelKey] = effectiveTTYWasReportedInCurrentSession
            commandPaletteForkableAgentProbeCompletedAtByPanelKey[panelKey] = CACurrentMediaTime()

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
    static func commandPaletteForkCachedSnapshot(
        panelKey: String,
        cachedSnapshot: SessionRestorableAgentSnapshot?,
        cachedRemoteContextsByPanelKey: [String: Bool],
        cachedTTYNamesByPanelKey: [String: String],
        cachedTTYFreshByPanelKey: [String: Bool],
        isRemoteTerminal: Bool,
        ttyName: String?,
        ttyWasReportedInCurrentSession: Bool
    ) -> SessionRestorableAgentSnapshot? {
        guard let cachedSnapshot,
              cachedRemoteContextsByPanelKey[panelKey] == isRemoteTerminal,
              cachedTTYNamesByPanelKey[panelKey] == commandPaletteTTYCacheValue(ttyName),
              cachedTTYFreshByPanelKey[panelKey] == ttyWasReportedInCurrentSession else {
            return nil
        }
        return cachedSnapshot
    }

    static func commandPaletteForkExecutionSnapshot(
        indexSnapshot: SessionRestorableAgentSnapshot?,
        fallbackSnapshot: SessionRestorableAgentSnapshot?,
        cachedSnapshot: SessionRestorableAgentSnapshot?
    ) -> SessionRestorableAgentSnapshot? {
        indexSnapshot ?? fallbackSnapshot ?? cachedSnapshot
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

    static func commandPaletteForkPostProbeTTYStillMatches(
        expectedTTYWasReportedInCurrentSession: Bool,
        currentTTYWasReportedInCurrentSession: Bool,
        expectedTTYName: String?,
        currentTTYName: String?
    ) -> Bool {
        if expectedTTYWasReportedInCurrentSession == currentTTYWasReportedInCurrentSession {
            return true
        }
        return !expectedTTYWasReportedInCurrentSession &&
            currentTTYWasReportedInCurrentSession &&
            commandPaletteNormalizedTTYName(currentTTYName) == commandPaletteNormalizedTTYName(expectedTTYName)
    }

    static func commandPaletteProcessDetectionFallbackScope(
        workspaceId: UUID,
        panelId: UUID,
        isRemoteTerminal: Bool,
        ttyWasReportedInCurrentSession: Bool,
        ttyName: String?
    ) -> RestorableAgentProcessDetectionScope? {
        guard !isRemoteTerminal else { return nil }
        guard let normalizedTTYName = commandPaletteNormalizedTTYName(ttyName) else {
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
