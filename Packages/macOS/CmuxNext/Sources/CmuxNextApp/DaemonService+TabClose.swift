import CmuxNextDaemon

extension DaemonService {
    typealias TabCloseCommand = (label: String, run: @Sendable (DaemonConnection) async throws -> Void)

    /// The daemon command that closes `tab`, shared by the strip, the
    /// palette, the menu, and the CLI. While the owner's reaper runs
    /// (`terminal-reaper-active-v1`) a terminal tab only detaches
    /// (`close-surface`): the daemon ends the terminal after its reap grace
    /// period unless it is kept, so Reopen Closed Tab can show it again
    /// meanwhile. An owner without a running reaper (an older daemon, or one
    /// started without a reap grace) keeps detached terminals until the
    /// session ends, so there the tab ends its terminal (`close-terminal`)
    /// and Reopen Closed Tab starts a new shell in the saved directory.
    func closeCommand(for tab: TabModel) -> TabCloseCommand {
        Self.closeCommand(for: tab, reaps: Self.reapsDetachedTerminals(supports))
    }

    /// Whether a closed terminal tab may only detach its terminal:
    /// `terminal-reap-v1` says the daemon can reap, not that it does.
    static func reapsDetachedTerminals(_ supports: (String) -> Bool) -> Bool {
        supports(DaemonCapabilities.shared.terminalReaperActive)
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
