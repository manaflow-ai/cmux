import Foundation

extension DockSplitStore {
    /// Returns a source directory only when it is valid for a new local terminal.
    func inheritedLocalTerminalWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard detachedSurfaceTransfersByPanelId[sourcePanelId]?.isRemoteTerminal != true else { return nil }
        return terminalWorkingDirectory(for: sourcePanelId)
    }

    /// Returns the best current directory owned by a Dock terminal.
    ///
    /// Local terminals prefer the shell integration report owned by their
    /// surface, then fall back to foreground-process inspection. A restored
    /// agent that is still auto-resuming retains the pre-report candidate order
    /// so an early shell-home report cannot bypass its cwd rescue state. Remote
    /// terminals must keep their transferred remote directory because their
    /// local process is only the relay.
    func terminalWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard let terminal = panels[sourcePanelId] as? TerminalPanel else { return nil }
        let transfer = detachedSurfaceTransfersByPanelId[sourcePanelId]
        if transfer?.isRemoteTerminal == true {
            return TerminalWorkingDirectoryResolver.firstAvailable([
                transfer?.directory,
                terminal.directory,
                terminal.requestedWorkingDirectory,
            ])
        }
        let existingCandidates = [
            terminalWorkingDirectoryResolver.liveForegroundProcessWorkingDirectory(for: terminal),
            terminal.directory,
            transfer?.directory,
            terminal.requestedWorkingDirectory,
        ]
        let reportedDirectory = terminal.surface.reportedWorkingDirectory
        if restoredAgentLifecycle.resumeStatesByPanelId[sourcePanelId] == .autoResumeCommandRunning {
            return TerminalWorkingDirectoryResolver.firstAvailable(existingCandidates + [reportedDirectory])
        }
        return TerminalWorkingDirectoryResolver.firstAvailable([reportedDirectory] + existingCandidates)
    }
}
