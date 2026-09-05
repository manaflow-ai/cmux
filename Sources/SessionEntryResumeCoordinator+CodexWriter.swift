import AppKit
import CMUXAgentLaunch
import Foundation

@MainActor
extension SessionEntryResumeCoordinator {
    /// Codex alone has a single-writer navigation policy. No saved snapshot or
    /// process-reported CMUX/tty label can authorize continuation.
    func handleCodexWriterConflict(for entry: SessionEntry) async -> Bool {
        guard entry.agent == .codex, let launch = entry.resumeLaunch,
              let snapshot = launch.startupRestoreAgent else { return false }
        let command = snapshot.launchCommand
        let environment = ProcessInfo.processInfo.environment.merging(command?.environment ?? [:]) { _, saved in saved }
        let cwd = launch.workingDirectory ?? FileManager.default.currentDirectoryPath
        let fallbackHome = NSHomeDirectory()
        let sessionID = entry.sessionId
        let arguments = command?.arguments ?? ["codex"]
        let task = Task.detached(priority: .userInitiated) {
            CodexWriterRestorePreflight().inspect(
                sessionID: sessionID, arguments: arguments, environment: environment,
                workingDirectory: cwd, fallbackHome: fallbackHome
            )
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled else { return true }
        if result.permitsLaunch { return false }
        if let target = result.mappedSurface(in: codexWriterSurfaces()),
           let owner = result.owners.first, let lock = result.lock {
            let confirmation = Task.detached(priority: .userInitiated) {
                let processes = CodexWriterProcessInspector()
                return processes.isCurrent(owner, inspection: lock)
                    && processes.descendsFromForeground(owner, foregroundPID: target.foregroundPID)
                    && CodexWriterLockInspector().inspect(sessionID: sessionID, codexHome: lock.codexHome) == lock
            }
            let confirmed = await withTaskCancellationHandler { await confirmation.value } onCancel: { confirmation.cancel() }
            guard !Task.isCancelled else { return true }
            // The panel can move or restart while process I/O is in flight.
            if confirmed, codexWriterSurfaces().contains(target) {
                if let workspace = tabManager.tabs.first(where: { $0.id == target.containerID }) {
                    tabManager.focusTab(workspace.id, surfaceId: target.surfaceID)
                    return true
                }
                if let dock = tabManager.liveWindowDockStores.first(where: { $0.workspaceId == target.containerID }) {
                    dock.focusPanelFromDockInteraction(target.surfaceID, window: nil)
                    return true
                }
            }
        }
        let message = CodexWriterRestoreMessage(sessionID: sessionID, inspection: result)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message.title
        alert.informativeText = message.text
        alert.addButton(withTitle: String(localized: "alert.ok", defaultValue: "OK"))
        _ = alert.runModal()
        return true
    }

    private func codexWriterSurfaces() -> [CodexWriterSurfaceIdentity] {
        var candidates: [CodexWriterSurfaceIdentity] = []
        for workspace in tabManager.tabs
        where !workspace.isRetiredFromOwningTabManager && !workspace.isRemoteWorkspace && !workspace.isRemoteTmuxMirror {
            for (panelID, panel) in workspace.panels {
                guard !workspace.isRemoteTerminalSurface(panelID),
                      let terminal = panel as? TerminalPanel, terminal.surface.hasLiveSurface,
                      let foregroundPID = terminal.surface.foregroundProcessID(),
                      let ttyDevice = terminal.surface.controllingTTYDeviceIdentifier else { continue }
                candidates.append(CodexWriterSurfaceIdentity(
                    containerID: workspace.id, surfaceID: panelID,
                    generation: terminal.surface.runtimeSurfaceGeneration, foregroundPID: foregroundPID, ttyDevice: ttyDevice
                ))
            }
        }
        // Scope to this window's rendered Dock. Legacy workspace Docks and
        // remote/mirrored surfaces have no safe continuation route here.
        for dock in tabManager.liveWindowDockStores where dock.scope == .global && !dock.isRetired {
            for (panelID, panel) in dock.panels {
                guard let terminal = panel as? TerminalPanel, terminal.surface.hasLiveSurface,
                      let foregroundPID = terminal.surface.foregroundProcessID(),
                      let ttyDevice = terminal.surface.controllingTTYDeviceIdentifier else { continue }
                candidates.append(CodexWriterSurfaceIdentity(
                    containerID: dock.workspaceId, surfaceID: panelID,
                    generation: terminal.surface.runtimeSurfaceGeneration, foregroundPID: foregroundPID, ttyDevice: ttyDevice
                ))
            }
        }
        return candidates
    }
}
