import Foundation

extension DockSplitStore {
    /// Returns a source directory only when it is valid for a new local terminal.
    func inheritedLocalTerminalWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard detachedSurfaceTransfersByPanelId[sourcePanelId]?.isRemoteTerminal != true else { return nil }
        return terminalWorkingDirectory(for: sourcePanelId)
    }

    /// Returns the best current directory owned by a Dock terminal.
    ///
    /// Local terminals prefer the foreground process because the Dock does not
    /// receive main-workspace cwd reports. Remote terminals must keep their
    /// transferred remote directory because their local foreground process is
    /// only the relay.
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
        return TerminalWorkingDirectoryResolver.firstAvailable([
            terminalWorkingDirectoryResolver.liveForegroundProcessWorkingDirectory(for: terminal),
            terminal.directory,
            transfer?.directory,
            terminal.requestedWorkingDirectory,
        ])
    }
}
