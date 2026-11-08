import CmuxNextCompat
import CmuxNextDaemonService
import CmuxNextWakeups

/// A chat clicked while this Mac's sessions are not ready waits and opens once they are, instead of doing
/// nothing (Leo, 2026-11-08: "me trying to click into any other chat in the sidebar doesn't work ... it fixes
/// itself"). One open waits at a time (``PendingOpenSlot``): a newer click replaces it, and a quiet toast says it
/// opens when the sessions are restored. It runs when the local daemon is connected and its mirror loaded,
/// followed by Observation, never polled.
///
/// Stop condition: the open is dropped, with one toast that says so, when the window it was clicked in closes
/// or after ``PendingOpenPatience/limit`` (one ``DemandTimer`` deadline). The watch ends with the open.
@MainActor
final class PendingSessionOpen {
    private weak var services: AppServices?
    private var slot = PendingOpenSlot<@MainActor () -> Void>()
    /// The window the waiting open was clicked in; `hadOrigin` false when no window was active.
    private weak var origin: WindowController?
    private var hadOrigin = false
    private var watch: Task<Void, Never>?
    private let expiry: DemandTimer
    /// Now, for the slot's patience (tests move it).
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }

    init(services: AppServices, clock: any Clock<Duration> = ContinuousClock()) {
        self.services = services
        expiry = DemandTimer(owner: "chats.pendingOpen", clock: clock)
    }

    /// An open waits now.
    var isWaiting: Bool { slot.isWaiting }

    /// Whether the local daemon takes an open now: connected, its mirror loaded.
    static func ready(_ daemon: DaemonService) -> Bool {
        daemon.isLive && daemon.store.isLoaded
    }

    /// Keeps `open` for later and returns true when the sessions are not ready; false (and nothing kept) when
    /// they are, so the caller opens now.
    func holds(_ open: @escaping @MainActor () -> Void) -> Bool {
        guard let services, !Self.ready(services.daemon) else { return false }
        let window = services.windows.active
        origin = window
        hadOrigin = window != nil
        slot.hold(open, at: now())
        services.refusalHUD.show(MiscHandlerStrings.pendingOpenWaits, in: window?.window ?? services.keyWindowSource())
        expiry.schedule(after: PendingOpenPatience.limit) { @MainActor [weak self] in
            _ = self?.advance()
        }
        guard watch == nil else { return true }
        let daemon = services.daemon
        // task-owner: this coordinator (app lifetime); ends when the open runs or is dropped (`advance`).
        watch = Task { [weak self] in
            for await _ in ObservationStream({ Self.ready(daemon) }) {
                guard let self else { return }
                if advance() { return }
            }
        }
        return true
    }

    /// Runs or drops the waiting open when its time came; true once none waits.
    private func advance() -> Bool {
        guard let services else { return true }
        let windowOpen = !hadOrigin || origin.map { origin in services.windows.controllers.contains { $0 === origin } } == true
        guard let outcome = slot.step(ready: Self.ready(services.daemon), windowOpen: windowOpen, now: now()) else {
            return !slot.isWaiting
        }
        expiry.cancel()
        watch?.cancel()
        watch = nil
        origin = nil
        switch outcome {
        case .run(let open):
            open()
        case .drop:
            services.refusalHUD.show(MiscHandlerStrings.pendingOpenDropped, in: services.windows.active?.window ?? services.keyWindowSource())
        }
        return true
    }
}
