import AppKit
import Foundation
import os

nonisolated private let agentConversationForkRequestLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "AgentConversationForkRequest"
)

extension Workspace {
    func adoptConversationTransferLauncher(
        _ input: PreparedAgentStartupInput?,
        forPanelId panelId: UUID
    ) {
        OneShotTerminalLauncherOwnershipRegistry.shared.adopt(
            input,
            forPanelID: panelId
        )
    }

    /// Executes a validated request after the caller resolves the source snapshot.
    func forkAgentConversation(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        request: AgentConversationForkRequest,
        exportService: AgentConversationExportService = .live,
        liveAgentIndex: SharedLiveAgentIndex? = nil,
        launcherTemporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) async -> Bool {
        let liveAgentIndex = liveAgentIndex ?? .shared
        guard let sourcePanel = panels[panelId] as? TerminalPanel else {
            return false
        }
        let sourceIsRemote = isRemoteTerminalSurface(panelId)
        guard request.targetHarness.supportsFork(
            from: snapshot.kind,
            isRemoteSource: sourceIsRemote
        ) else {
            return false
        }
        let sourceSnapshotFingerprint = ContentView.commandPaletteForkSnapshotFingerprint(
            snapshot,
            isRemoteTerminal: sourceIsRemote
        )
        guard let initialSelection = agentConversationForkSelection(
            forPanelId: panelId,
            request: request,
            liveAgentIndex: liveAgentIndex
        ),
              ContentView.commandPaletteForkSnapshotFingerprint(
                  initialSelection.snapshot,
                  isRemoteTerminal: sourceIsRemote
              ) == sourceSnapshotFingerprint else {
            return false
        }
        let usesNativeFork = initialSelection.requiresNativeForkCapability
        guard usesNativeFork
            ? snapshot.forkCommand != nil
            : AgentConversationSource(snapshot: snapshot).hasDeterministicTranscriptSource else {
            return false
        }
        let transferPanelStateToken: AgentConversationPanelStateToken?
        let initialTransferEvidence: SharedLiveAgentIndex.ConversationTransferEvidence?
        if usesNativeFork {
            transferPanelStateToken = nil
            initialTransferEvidence = nil
        } else {
            guard let selectedTransferIdentity = AgentConversationSource(
                snapshot: snapshot
            ).transferIdentity,
                  let freshEvidence = await liveAgentIndex.freshConversationTransferEvidence(
                      workspaceId: id,
                      panelId: panelId
                  ),
                  freshEvidence.transferIdentity == selectedTransferIdentity,
                  panels[panelId] as? TerminalPanel === sourcePanel,
                  isRemoteTerminalSurface(panelId) == sourceIsRemote else {
                return false
            }
            initialTransferEvidence = freshEvidence
            transferPanelStateToken = agentConversationPanelStateToken(
                forPanelId: panelId
            )
        }
        let startupCommandOverride: String?
        do {
            startupCommandOverride = try await request.startupCommandOverride(
                sourceSnapshot: snapshot,
                expectedTransferIdentity: initialTransferEvidence?.transferIdentity,
                forceConversationTransfer: !usesNativeFork,
                exportService: exportService
            )
        } catch {
            agentConversationForkRequestLogger.error(
                "Conversation export failed kind=\(snapshot.kind.rawValue, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
            presentConversationTransferFailure()
            return false
        }

        if let initialTransferEvidence {
            let postExportRefreshBoundary = liveAgentIndex
                .conversationTransferRefreshBoundary()
            guard let refreshedEvidence = await liveAgentIndex.freshConversationTransferEvidence(
                workspaceId: id,
                panelId: panelId,
                startedAfter: postExportRefreshBoundary
            ),
            Self.sameConversationTransferEvidence(
                initialTransferEvidence,
                refreshedEvidence
            ) else {
                return false
            }
        }
        if let transferPanelStateToken,
           agentConversationPanelStateToken(forPanelId: panelId)
            != transferPanelStateToken {
            return false
        }
        let refreshedSelection = agentConversationForkSelection(
            forPanelId: panelId,
            request: request,
            liveAgentIndex: liveAgentIndex
        )
        guard panels[panelId] as? TerminalPanel === sourcePanel,
              isRemoteTerminalSurface(panelId) == sourceIsRemote,
              refreshedSelection?.requiresNativeForkCapability == usesNativeFork,
              let refreshedSnapshot = refreshedSelection?.snapshot,
              ContentView.commandPaletteForkSnapshotFingerprint(
                  refreshedSnapshot,
                  isRemoteTerminal: sourceIsRemote
              ) == sourceSnapshotFingerprint else {
            return false
        }

        let preparedStartupInput = startupCommandOverride.flatMap {
            snapshot.preparedCustomStartupInput(
                command: $0,
                temporaryDirectory: launcherTemporaryDirectory,
                allowLauncherScript: !sourceIsRemote,
                allowOversizedInlineInput: sourceIsRemote
            )
        }
        if startupCommandOverride != nil, preparedStartupInput == nil {
            presentConversationTransferFailure()
            return false
        }
        var destinationOwnsLauncherScript = false
        defer {
            if !destinationOwnsLauncherScript {
                preparedStartupInput?.removeLauncherScript()
            }
        }
        guard !Task.isCancelled else {
            return false
        }
        let startupInputOverride = preparedStartupInput?.text

        if let direction = request.destination.splitDirection {
            guard let destinationPanel = forkAgentConversation(
                fromPanelId: panelId,
                snapshot: snapshot,
                direction: direction,
                startupInputOverride: startupInputOverride
            ) else {
                return false
            }
            adoptConversationTransferLauncher(
                preparedStartupInput,
                forPanelId: destinationPanel.id
            )
            destinationOwnsLauncherScript = true
            return true
        }

        switch request.destination {
        case .newTab:
            guard let anchorTabId = surfaceIdFromPanelId(panelId),
                  let paneId = paneId(forPanelId: panelId) else {
                return false
            }
            guard let destinationPanel = forkAgentConversationToNewTab(
                fromPanelId: panelId,
                snapshot: snapshot,
                anchorTabId: anchorTabId,
                paneId: paneId,
                startupInputOverride: startupInputOverride
            ) else {
                return false
            }
            adoptConversationTransferLauncher(
                preparedStartupInput,
                forPanelId: destinationPanel.id
            )
            destinationOwnsLauncherScript = true
            return true
        case .newWorkspace:
            guard let destination = forkAgentConversationToNewWorkspace(
                fromPanelId: panelId,
                snapshot: snapshot,
                startupInputOverride: startupInputOverride
            ) else {
                return false
            }
            destination.workspace.adoptConversationTransferLauncher(
                preparedStartupInput,
                forPanelId: destination.panelId
            )
            destinationOwnsLauncherScript = true
            return true
        case .right, .left, .top, .bottom:
            return false
        }
    }

    private func presentConversationTransferFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "alert.forkConversation.failed.title",
            defaultValue: "Couldn’t Fork Conversation"
        )
        alert.informativeText = String(
            localized: "alert.forkConversation.failed.message",
            defaultValue: "cmux couldn’t read and transfer the source conversation. The original conversation was not changed."
        )
        alert.addButton(withTitle: String(localized: "alert.ok", defaultValue: "OK"))
        _ = alert.runCmuxModal(
            presentingWindow: AppDelegate.shared?.mainWindowContainingWorkspace(id)
        )
    }

    private func agentConversationPanelStateToken(
        forPanelId panelId: UUID
    ) -> AgentConversationPanelStateToken {
        let restoredTransferIdentity = restoredAgentSnapshotsByPanelId[panelId]
            .flatMap { AgentConversationSource(snapshot: $0).transferIdentity }
        let binding = surfaceResumeBinding(panelId: panelId)
        let bindingSource = Self.normalizedConversationIdentityValue(binding?.source)
        let bindingKind = Self.normalizedConversationIdentityValue(binding?.kind)
        let bindingSessionId = bindingKind.flatMap { kind in
            Self.normalizedConversationIdentityValue(binding?.checkpointId).map {
                ManagedAgentSessionIdentity.canonicalSessionID(
                    kind: kind,
                    sessionID: $0
                )
            }
        }
        let runtimeProcessIdentities = (agentPIDKeysByPanelId[panelId] ?? [])
            .sorted()
            .map { key in
                AgentConversationRuntimeProcessIdentity(
                    key: key,
                    pid: agentPIDs[key],
                    processIdentity: agentPIDProcessIdentitiesByKey[key]
                )
            }
        return AgentConversationPanelStateToken(
            restoredTransferIdentity: restoredTransferIdentity,
            bindingSource: bindingSource,
            bindingKind: bindingKind,
            bindingSessionId: bindingSessionId,
            runtimeProcessIdentities: runtimeProcessIdentities
        )
    }

    private static func normalizedConversationIdentityValue(
        _ value: String?
    ) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    private static func sameConversationTransferEvidence(
        _ lhs: SharedLiveAgentIndex.ConversationTransferEvidence,
        _ rhs: SharedLiveAgentIndex.ConversationTransferEvidence
    ) -> Bool {
        lhs.transferIdentity == rhs.transferIdentity
            && lhs.processLiveness == rhs.processLiveness
            && lhs.processIDs == rhs.processIDs
            && lhs.processIdentities == rhs.processIdentities
            && lhs.agentProcessIDs == rhs.agentProcessIDs
            && lhs.agentProcessIdentities == rhs.agentProcessIdentities
    }

    private func forkAgentConversationToNewWorkspace(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        startupInputOverride: String?
    ) -> (workspace: Workspace, panelId: UUID)? {
        guard let owningTabManager,
              let launch = forkAgentWorkspaceLaunch(
                  fromPanelId: panelId,
                  snapshot: snapshot,
                  startupInputOverride: startupInputOverride
              ) else {
            return nil
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
        guard let forkPanelId = forkWorkspace.focusedPanelId else {
            return nil
        }
        return (forkWorkspace, forkPanelId)
    }
}
