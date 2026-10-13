import CmuxNextDaemon

/// A new terminal opened from a tab that shows another machine's terminal
/// (a mixed workspace, plans/cmux-next/data-model.md 1.2b) runs on that
/// machine, like its folder follows the selected tab (cx-2s5t). Only the
/// app knows every session, so the choice of daemon is made here; the
/// terminal itself is created by its own session (`openTerminal`).
extension RemoteTerminalService {
    /// The machine whose terminal `tab` shows, when that is not `home`
    /// (the pane's own session). Nil for every other tab.
    func machine(of tab: TabModel?, home: DaemonService) -> DaemonService? {
        guard let tab, tab.kind == .remoteTerminal, let ref = tab.remote,
              let machine = services.machines.daemon(session: ref.sessionID), machine !== home else { return nil }
        return machine
    }

    /// Opens a new terminal on the machine of `tab` in `pane`. False when
    /// `tab` shows no other machine's terminal (the caller opens one on
    /// `home`). A machine that is not connected refuses, never falls back
    /// to `home`: the user asked for a terminal on that machine.
    func openTerminal(besides tab: TabModel?, in pane: PaneModel, home: DaemonService, cwd: String?) -> Bool {
        guard let machine = machine(of: tab, home: home) else { return false }
        if let failure = openTerminal(on: machine, in: pane, home: home, cwd: cwd) {
            services.registry.refuse(failure.message)
        }
        return true
    }
}
