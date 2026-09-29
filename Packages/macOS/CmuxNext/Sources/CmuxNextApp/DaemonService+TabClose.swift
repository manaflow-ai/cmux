import CmuxNextDaemon

extension DaemonService {
    typealias TabCloseCommand = (label: String, run: @Sendable (DaemonConnection) async throws -> Void)

    /// The daemon command that closes `tab`, shared by the strip, the
    /// palette, the menu, and the CLI. With `terminal-reap-v1` a terminal
    /// tab only detaches (`close-surface`): the daemon ends the terminal
    /// after its reap grace period unless it is kept, so Reopen Closed Tab
    /// can show it again meanwhile. Older daemons keep detached terminals
    /// forever, so there the tab ends its terminal (`close-terminal`).
    func closeCommand(for tab: TabModel) -> TabCloseCommand {
        Self.closeCommand(for: tab, reaps: supports(DaemonCapabilities.terminalReap))
    }

    static func closeCommand(for tab: TabModel, reaps: Bool) -> TabCloseCommand {
        if tab.kind == .pty, !reaps, let terminal = tab.terminalID {
            let incarnation = tab.terminalIncarnation
            return ("close-terminal", { try await $0.closeTerminal(terminal, incarnation: incarnation) })
        }
        let surface = tab.surface
        return ("close-surface", { try await $0.closeTab(surface) })
    }
}
