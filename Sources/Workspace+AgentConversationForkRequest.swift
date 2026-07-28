import Foundation
import os

nonisolated private let agentConversationForkRequestLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "AgentConversationForkRequest"
)

extension Workspace {
    /// Executes a validated request after the caller resolves the source snapshot.
    func forkAgentConversation(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        request: AgentConversationForkRequest,
        exportService: AgentConversationExportService = .live
    ) async -> Bool {
        guard let sourcePanel = panels[panelId] as? TerminalPanel else {
            return false
        }
        let sourceIsRemote = isRemoteTerminalSurface(panelId)
        let sourceSnapshotFingerprint = ContentView.commandPaletteForkSnapshotFingerprint(
            snapshot,
            isRemoteTerminal: sourceIsRemote
        )
        let startupCommandOverride: String?
        do {
            startupCommandOverride = try await request.startupCommandOverride(
                sourceSnapshot: snapshot,
                exportService: exportService
            )
        } catch {
            agentConversationForkRequestLogger.error(
                "Conversation export failed kind=\(snapshot.kind.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        let refreshedSelection = forkAgentConversationContextMenuOpenSelection(forPanelId: panelId)
        guard panels[panelId] as? TerminalPanel === sourcePanel,
              isRemoteTerminalSurface(panelId) == sourceIsRemote,
              refreshedSelection.availability.isAvailable,
              let refreshedSnapshot = refreshedSelection.snapshot,
              ContentView.commandPaletteForkSnapshotFingerprint(
                  refreshedSnapshot,
                  isRemoteTerminal: sourceIsRemote
              ) == sourceSnapshotFingerprint else {
            return false
        }

        let startupInputOverride = startupCommandOverride.flatMap {
            snapshot.customStartupInput(
                command: $0,
                allowLauncherScript: !sourceIsRemote,
                allowOversizedInlineInput: sourceIsRemote
            )
        }
        if startupCommandOverride != nil, startupInputOverride == nil {
            return false
        }

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
            guard let anchorTabId = surfaceIdFromPanelId(panelId),
                  let paneId = paneId(forPanelId: panelId) else {
                return false
            }
            return forkAgentConversationToNewTab(
                fromPanelId: panelId,
                snapshot: snapshot,
                anchorTabId: anchorTabId,
                paneId: paneId,
                startupInputOverride: startupInputOverride
            ) != nil
        case .newWorkspace:
            return forkAgentConversationToNewWorkspace(
                fromPanelId: panelId,
                snapshot: snapshot,
                startupInputOverride: startupInputOverride
            )
        case .right, .left, .top, .bottom:
            return false
        }
    }

    private func forkAgentConversationToNewWorkspace(
        fromPanelId panelId: UUID,
        snapshot: SessionRestorableAgentSnapshot,
        startupInputOverride: String?
    ) -> Bool {
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
    }
}
