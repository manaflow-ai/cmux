public import CmuxNextDaemon

extension DaemonService {
    public typealias TabCloseCommand = (label: String, run: DaemonCommandBody)

    /// The daemon command that closes `tab`, shared by the strip, the
    /// palette, the menu, and the CLI. While the owner's reaper runs
    /// (`terminal-reaper-active-v1`) a terminal tab only detaches
    /// (`close-surface`): the daemon ends the terminal after its reap grace
    /// period unless it is kept, so Reopen Closed Tab can show it again
    /// meanwhile. An owner without a running reaper (an older daemon, or one
    /// started without a reap grace) keeps detached terminals until the
    /// session ends, so there the tab ends its terminal (`close-terminal`)
    /// and Reopen Closed Tab starts a new shell in the saved directory.
    public func closeCommand(for tab: TabModel) -> TabCloseCommand {
        let close = Self.closeCommand(for: tab, reaps: Self.reapsDetachedTerminals(supports))
        guard tab.kind == .browser else { return close }
        return (close.label, preparingClose(of: [tab.surface], then: close.run))
    }

    /// What the app saves before tabs close, by machine and surface: the
    /// daemon copies a browser page's stored history into Reopen Closed at
    /// the close and then deletes it (cx-d0d.73). The browser service sets it.
    public static var prepareClose: @MainActor @Sendable (_ machine: String, _ surfaces: [SurfaceID]) async -> Void = preparesNothing

    /// The default ``prepareClose``: a named function, never an async closure literal (crash ratchet).
    private static func preparesNothing(_ machine: String, _ surfaces: [SurfaceID]) async {}

    /// `run`, after ``prepareClose`` for `surfaces` on this machine.
    func preparingClose(of surfaces: [SurfaceID], then run: @escaping DaemonCommandBody) -> DaemonCommandBody {
        let prepare = Self.prepareClose, machine = machineID
        return { connection in
            await prepare(machine, surfaces)
            try await run(connection)
        }
    }

    /// Whether a closed terminal tab may only detach its terminal:
    /// `terminal-reap-v1` says the daemon can reap, not that it does.
    static func reapsDetachedTerminals(_ supports: (String) -> Bool) -> Bool {
        supports(DaemonCapability.terminalReaperActive.rawValue)
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
