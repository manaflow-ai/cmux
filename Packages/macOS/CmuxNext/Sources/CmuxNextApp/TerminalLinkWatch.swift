import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTerminal
import CmuxNextWakeups

extension TerminalCursorDefault {
    /// The user's Ghostty `cursor-style` and `cursor-style-blink`.
    @MainActor static var user: TerminalCursorDefault {
        GhosttyRuntime.shared.cursorDefaults.map { TerminalCursorDefault(style: $0.style, blink: $0.blink) } ?? .ghostty
    }
}

/// Tells one terminal view about daemon facts its stream cannot: the
/// terminal's process ended (tab `dead`), its shell's host link is down
/// (tab `terminal_state`, a labeled stall), or the terminal or the daemon connection came
/// back (a new `connectionEpoch`, even one missed between hops), which re-attaches a disconnected view. Tells the
/// store the folder the shell reported to the view (OSC 7). One
/// `ServiceObservation`: a burst of changes is one read
/// and one `changed()` in a scheduled task, and it follows while the
/// terminal is hidden too (a process exit and the folder are not view work).
/// Nothing polls.
@MainActor
final class TerminalLinkWatch {
    private weak var store: DaemonStore?
    private weak var io: DaemonTerminalIO?
    private weak var model: TerminalSurfaceModel?
    private weak var session: TerminalSession?
    private let surface: SurfaceID
    private var epoch: Int
    private var dead: Bool
    private var stall: TerminalShellStall?
    /// The shell's folder last told to the store; only a new one is sent, so
    /// a reconnect never repeats an old view's folder onto a reused surface.
    private var directory: String?
    private var stopped = false
    /// The daemon facts this view follows; cancelled by ``stop()``.
    private var facts: ServiceObservation<Void>?

    // cx-qxxu: released with its terminal, which Cmd-T's New Tab page can withdraw while its
    // action runs; a main-actor deinit's hop traps there (cx-t7hu).
    nonisolated deinit {}

    /// `mainWork`: the app's one main-thread scheduler, which runs the follow-up of each batch of changes.
    init(store: DaemonStore, surface: SurfaceID, io: DaemonTerminalIO, session: TerminalSession, mainWork: MainWorkScheduler) {
        self.store = store
        self.surface = surface
        self.io = io
        self.session = session
        model = session.model
        epoch = store.connectionEpoch
        dead = store.tab(surface: surface)?.dead ?? false
        if dead { io.processExited() }
        stall = Self.shellStall(store.tab(surface: surface))
        session.shellStall = stall
        // The first read forwards the host loss and the folder now; each later batch runs `changed()` once.
        let surfaceModel = session.model
        facts = ServiceObservation(.visible, owner: "TerminalLinkWatch", on: mainWork) { [weak store, weak surfaceModel] in
            Self.readFacts(store, surface: surface, model: surfaceModel)
        } apply: { [weak self] _ in
            self?.changed()
        }
    }

    func stop() {
        stopped = true
        facts?.cancel()
        facts = nil
    }

    /// Reads what ``changed()`` acts on, so a change of any of it schedules one call.
    private static func readFacts(_ store: DaemonStore?, surface: SurfaceID, model: TerminalSurfaceModel?) {
        guard let store else { return }
        _ = store.connectionState
        let tab = store.tab(surface: surface)
        _ = tab?.dead
        _ = tab?.end
        _ = tab?.terminalState
        _ = model?.workingDirectory
    }

    private func changed() {
        guard !stopped, let store, let io else { return }
        let nowEpoch = store.connectionEpoch
        let nowDead = store.tab(surface: surface)?.dead ?? dead
        let nowStall = Self.shellStall(store.tab(surface: surface))
        if nowDead, !dead {
            io.processExited()
        } else if dead, !nowDead {
            // The daemon reported the terminal dead and now running (R41): a
            // dead report can be transient, so the view must leave "exited".
            io.processRevived()
        } else if Self.isConnected(store.connectionState), nowEpoch != epoch {
            io.reconnect()
        } else if stall != nil, nowStall == nil {
            // The shell is reachable again: a view whose attach failed meanwhile re-attaches.
            io.reconnect()
        }
        epoch = nowEpoch
        dead = nowDead
        stall = nowStall
        session?.shellStall = nowStall
        forwardHostLoss()
        forwardDirectory()
    }

    /// The stall a tab's `terminal_state` names: a live (not dead) terminal
    /// whose shell the daemon cannot reach now. Nil while it runs, once it
    /// ended, and from daemons that do not report the state.
    static func shellStall(_ tab: TabModel?) -> TerminalShellStall? {
        guard let tab, !tab.dead else { return nil }
        switch tab.terminalState {
        case .reconnecting?, .adopting?: return .reconnecting
        case .failed?: return .linkLost
        case .unadoptable?: return .otherBuild
        case .running?, .exited?, nil: return nil
        }
    }

    /// The banner names a lost host only while the tab is dead with a
    /// `host_lost` end; a revived or normally ended terminal clears it.
    private func forwardHostLoss() {
        let tab = store?.tab(surface: surface)
        let loss = (tab?.dead ?? false) ? Self.hostLoss(tab?.end) : nil
        session?.hostLossCause = loss == nil ? nil : tab?.end?.cause.map(Self.hostLossCause)
        session?.hostLoss = loss
    }

    /// The banner's evidence for a host loss's `end.cause`.
    static func hostLossCause(_ cause: TerminalTabEnd.Cause) -> TerminalHostLossCause {
        TerminalHostLossCause(signal: cause.signal, senderPid: cause.senderPid,
                              senderName: cause.senderName, panicked: cause.panicked)
    }

    /// The banner's reason for a tab `end` (nil unless the host was lost).
    static func hostLoss(_ end: TerminalTabEnd?) -> TerminalHostLoss? {
        guard let end, end.kind == .hostLost else { return nil }
        switch end.reason {
        case .sessionShutdown: return .sessionShutdown
        case .missingRecord, .incarnationMismatch: return .hostMissing
        case .restartExhausted: return .restartExhausted
        case .restartFailed: return .restartFailed
        case .deadBeforeAdoption, .diedDuringAdoption, .diedWithoutExitStatus, .missingExitReceipt,
             .unadoptableHostEnded, .other, nil:
            return .hostEnded
        }
    }

    private func forwardDirectory() {
        guard let reported = model?.workingDirectory, reported != directory else { return }
        directory = reported
        store?.noteTerminalDirectory(reported, surface: surface)
    }

    private static func isConnected(_ state: DaemonConnectionState) -> Bool {
        if case .connected = state { return true }
        return false
    }
}
