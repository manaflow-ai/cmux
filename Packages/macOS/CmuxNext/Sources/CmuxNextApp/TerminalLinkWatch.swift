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
    private let surface: SurfaceID
    private var connected: Bool
    private var dead: Bool
    /// The terminal the view attached to. A restart (`tab.restart`) points
    /// the tab at a new one; the content cache then builds a new view, so
    /// this one never re-attaches to the dead terminal.
    private let terminal: ResourceID?
    /// The shell's folder last told to the store; only a new one is sent, so
    /// a reconnect never repeats an old view's folder onto a reused surface.
    private var directory: String?
    private var stopped = false

    init(store: DaemonStore, surface: SurfaceID, io: DaemonTerminalIO, model: TerminalSurfaceModel) {
        self.store = store
        self.surface = surface
        self.io = io
        self.model = model
        connected = Self.isConnected(store.connectionState)
        dead = store.tab(surface: surface)?.dead ?? false
        terminal = store.tab(surface: surface)?.terminalResourceID
        if dead { io.processExited() }
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
            _ = store.tab(surface: surface)?.terminalResourceID
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
        let restarted = store.tab(surface: surface).map { $0.terminalResourceID != terminal } ?? false
        if restarted {
            // Replaced by the content cache (its validity names the terminal).
        } else if nowDead, !dead {
            io.processExited()
        } else if (nowConnected && !connected) || (dead && !nowDead) {
            io.reconnect()
        }
        connected = nowConnected
        dead = nowDead
        forwardDirectory()
        arm()
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
