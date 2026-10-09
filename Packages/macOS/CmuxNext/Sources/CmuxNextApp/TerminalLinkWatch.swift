import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTerminal
import Observation

extension TerminalCursorDefault {
    /// The user's Ghostty `cursor-style` and `cursor-style-blink`.
    @MainActor static var user: TerminalCursorDefault {
        GhosttyRuntime.shared.cursorDefaults.map { TerminalCursorDefault(style: $0.style, blink: $0.blink) } ?? .ghostty
    }
}

/// Tells one terminal view about daemon facts its stream cannot: the
/// terminal's process ended (tab `dead`), or the terminal or the daemon
/// connection came back, which re-attaches a disconnected view. Tells the
/// store the folder the shell reported to the view (OSC 7). Observation
/// only (re-armed after each change); nothing polls.
@MainActor
final class TerminalLinkWatch {
    private weak var store: DaemonStore?
    private weak var io: DaemonTerminalIO?
    private weak var model: TerminalSurfaceModel?
    private weak var session: TerminalSession?
    private let surface: SurfaceID
    private var connected: Bool
    private var dead: Bool
    /// The shell's folder last told to the store; only a new one is sent, so
    /// a reconnect never repeats an old view's folder onto a reused surface.
    private var directory: String?
    private var stopped = false

    init(store: DaemonStore, surface: SurfaceID, io: DaemonTerminalIO, session: TerminalSession) {
        self.store = store
        self.surface = surface
        self.io = io
        self.session = session
        model = session.model
        connected = Self.isConnected(store.connectionState)
        dead = store.tab(surface: surface)?.dead ?? false
        if dead { io.processExited() }
        forwardHostLoss()
        forwardDirectory()
        arm()
    }

    func stop() { stopped = true }

    private func arm() {
        guard !stopped, let store else { return }
        let surface = surface
        withObservationTracking {
            _ = store.connectionState
            _ = store.tab(surface: surface)?.dead
            _ = store.tab(surface: surface)?.end
            _ = model?.workingDirectory
        } onChange: { [weak self] in
            // task-owner: one hop per observed change, re-arms itself; ends with the watch
            Task { @MainActor [weak self] in self?.changed() }
        }
    }

    private func changed() {
        guard !stopped, let store, let io else { return }
        let nowConnected = Self.isConnected(store.connectionState)
        let nowDead = store.tab(surface: surface)?.dead ?? dead
        if nowDead, !dead {
            io.processExited()
        } else if dead, !nowDead {
            // The daemon reported the terminal dead and now running (R41): a
            // dead report can be transient, so the view must leave "exited".
            io.processRevived()
        } else if nowConnected, !connected {
            io.reconnect()
        }
        connected = nowConnected
        dead = nowDead
        forwardHostLoss()
        forwardDirectory()
        arm()
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
