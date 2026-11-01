import AppKit
import CmuxNextCompat
import CmuxNextDaemon
public import CmuxNextDaemonService
import CmuxNextDesign

extension DaemonService {
    /// The local daemon's recovery wiring at the app's composition root, for the app's lifetime:
    /// the automatic restart's Debug Settings toggle, and the notice that offers Restart cmux-tui
    /// in a window that shows content (``DaemonRecoveryNotice``).
    public func installRecovery() {
        // A cmux-tui that stays alive but never answers restarts by itself (`UnresponsiveOwnerWatch`).
        recovery.restartsUnresponsiveOwner = { DaemonTunables.restartUnresponsiveCmuxTUI.value }
        DaemonRecoveryNotice(daemon: self).start()
    }
}

/// The way out in a window that shows content while the local cmux-tui is gone (restore fuzz h2):
/// the launch window's controls (`DaemonRecoveryControls`) show only before the first workspace,
/// so a daemon that died later left every window on its old content, "disconnected", with
/// nothing to press. While the local daemon is disconnected after it was connected, Restart
/// cmux-tui is offered (`DaemonRecovery.offersRestart`) and no restart runs, one notice shows that
/// stays until it ends: why cmux-tui is not running (a full disk is named) and Restart cmux-tui,
/// which asks first as the launch window's button does. The raw failure is the notice's detail.
/// It goes to the workspace window the key or main window acts for, else the frontmost visible
/// workspace window (as `DaemonUpdateBoard`'s notice does).
///
/// It ends by itself when the daemon is back, a restart starts or the offer ends. Closed by the
/// person, it stays closed until the daemon has connected again; a cancelled confirm shows it
/// again. It is a standard toast (`CmuxToastCenter`): its motion and keys are the toast's own.
@MainActor
final class DaemonRecoveryNotice {
    static let toastID = "daemon.recovery"

    /// What the notice shows now.
    enum Shown: Equatable, Sendable {
        /// The local daemon is connected (or still making its first connection): no notice, and a close is forgotten.
        case connected
        /// No notice: the offer is not up, or a restart runs.
        case hidden
        /// The notice: the reason the person reads, and the raw failure.
        case offer(message: String, detail: String?)
    }

    private let daemon: DaemonService
    private let toasts: CmuxToastCenter
    private let window: @MainActor () -> NSWindow?
    private var handle: CmuxToastHandle?
    /// The person closed the notice since the daemon last connected.
    private var closedByPerson = false
    private var current = Shown.connected
    private var observation: Task<Void, Never>?

    /// Follows `daemon` (the app's local one). `window` picks where the notice shows
    /// (``workspaceWindow()``); `toasts` and `window` are for tests.
    init(daemon: DaemonService, toasts: CmuxToastCenter = .shared,
         window: @escaping @MainActor () -> NSWindow? = DaemonRecoveryNotice.workspaceWindow) {
        self.daemon = daemon
        self.toasts = toasts
        self.window = window
    }

    /// The workspace window (``WindowKind/main``) the key or main window acts for, else the
    /// frontmost visible one.
    static func workspaceWindow() -> NSWindow? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0?.windowKindRoot } + NSApp.orderedWindows
        return candidates.first { $0.windowKind == .main && $0.isVisible }
    }

    /// Starts following the daemon; the observation keeps this notice until `stop()` (the app's local
    /// daemon lives as long as the app).
    func start() {
        guard observation == nil else { return }
        // task-owner: ends at `stop()`; one main-actor step per change of what the notice shows.
        observation = Task { [daemon] in
            for await shown in ObservationStream({ Self.shown(daemon) }) {
                self.apply(shown)
            }
        }
    }

    /// Ends the notice and stops following the daemon.
    func stop() {
        observation?.cancel()
        observation = nil
        end()
    }

    /// The toast this notice shows, if any (tests).
    var shownToast: CmuxToast? { handle.flatMap { $0.isDismissed ? nil : $0.toast } }

    /// What `daemon`'s state asks for. Reads the startup, the connection and the recovery only.
    static func shown(_ daemon: DaemonService) -> Shown {
        // Before the first connection the launch window shows the failure and its own controls.
        guard daemon.startup == .connected else { return .connected }
        switch daemon.store.connectionState {
        case .connected, .connecting: return .connected
        case .disconnected, .failed: break
        }
        let recovery = daemon.recovery
        guard recovery.offersRestart, !recovery.isRestarting else { return .hidden }
        let failure = recovery.startFailure
        return .offer(message: DaemonRecoveryStrings.startFailed(failure), detail: failure?.detail ?? recovery.restartFailure)
    }

    private func apply(_ shown: Shown) {
        current = shown
        switch shown {
        case .connected:
            closedByPerson = false
            end()
        case .hidden:
            end()
        case .offer(let message, let detail):
            guard !closedByPerson else { return }
            show(CmuxToast(id: Self.toastID, message: message, detail: detail,
                           action: CmuxToast.Action(title: DaemonRecoveryStrings.restart), duration: CmuxToast.untilClosed))
        }
    }

    private func show(_ toast: CmuxToast) {
        if let handle, !handle.isDismissed, handle.toast == toast { return }
        guard let window = window() else { return }
        // The same id replaces a notice that shows in that window (a new reason), in place.
        if let handle, !handle.isDismissed { end() }
        let shown = toasts.show(toast, in: window)
        handle = shown
        let recovery = daemon.recovery
        shown.onAction = { [weak self, weak window, weak recovery] in
            guard let recovery else { return }
            DaemonRestartPrompt.confirm(recovery, in: window, cancelled: { [weak self] in
                guard let self, observation != nil else { return }
                apply(current)
            })
        }
        shown.onDismiss = { [weak self, weak shown] reason in
            guard let self, let shown, handle === shown else { return }
            handle = nil
            if reason == .closed { closedByPerson = true }
        }
    }

    private func end() {
        let shown = handle
        handle = nil
        shown?.dismiss()
    }
}
