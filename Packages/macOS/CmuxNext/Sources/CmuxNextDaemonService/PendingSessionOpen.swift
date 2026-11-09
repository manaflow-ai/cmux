public import CmuxNextActions
import CmuxNextCompat
import CmuxNextWakeups

/// A chat clicked while this Mac's sessions are not ready waits and opens once they are, instead of doing
/// nothing (Leo, 2026-11-08: "me trying to click into any other chat in the sidebar doesn't work ... it fixes
/// itself"). One open waits at a time (``PendingOpenSlot``): a newer click replaces it, and a quiet toast says it
/// opens when the sessions are restored. It runs when the local daemon is connected and its mirror loaded,
/// followed by Observation, never polled. The App's Open Chat (`ChatsOpenCoordinator`) and the Chief sidebar's
/// subagent open go through it.
///
/// Stop condition: the open is dropped, with one toast that says so, when the window it was clicked in closes
/// or after ``PendingOpenPatience/limit`` (one ``DemandTimer`` deadline). The watch ends with the open.
@MainActor
public final class PendingSessionOpen {
    private let daemon: DaemonService
    /// The window an open is clicked in now (nil: none), and the windows still open.
    private let activeWindow: @MainActor () -> AnyObject?
    private let openWindows: @MainActor () -> [AnyObject]
    /// Shows a toast in the active window (the App's refusal HUD).
    private let show: @MainActor (String) -> Void
    private var slot = PendingOpenSlot<@MainActor () -> Void>()
    /// The window the waiting open was clicked in; `hadOrigin` false when no window was active.
    private weak var origin: AnyObject?
    private var hadOrigin = false
    private var watch: Task<Void, Never>?
    private let expiry: DemandTimer
    /// Now, for the slot's patience (tests move it).
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }

    public init(daemon: DaemonService, activeWindow: @escaping @MainActor () -> AnyObject?,
                openWindows: @escaping @MainActor () -> [AnyObject], show: @escaping @MainActor (String) -> Void,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.daemon = daemon
        self.activeWindow = activeWindow
        self.openWindows = openWindows
        self.show = show
        expiry = DemandTimer(owner: "chats.pendingOpen", clock: clock)
    }

    /// An open waits now.
    public var isWaiting: Bool { slot.isWaiting }

    /// Whether the local daemon takes an open now: connected, its mirror loaded.
    var ready: Bool { daemon.isLive && daemon.store.isLoaded }

    /// Keeps `open` for later and returns true when the sessions are not ready; false (and nothing kept) when
    /// they are, so the caller opens now.
    public func holds(_ open: @escaping @MainActor () -> Void) -> Bool {
        guard !ready else { return false }
        let window = activeWindow()
        origin = window
        hadOrigin = window != nil
        slot.hold(open, at: now())
        show(RefusalStrings.pendingOpenWaits)
        expiry.schedule(after: PendingOpenPatience.limit) { @MainActor [weak self] in
            _ = self?.advance()
        }
        guard watch == nil else { return true }
        let daemon = daemon
        // task-owner: the opener (app lifetime); ends when the open runs or is dropped (`advance`).
        watch = Task { [weak self] in
            for await _ in ObservationStream({ daemon.isLive && daemon.store.isLoaded }) {
                guard let self else { return }
                if advance() { return }
            }
        }
        return true
    }

    /// `make`'s work now when the sessions are ready. Else no work now (``holds(_:)``): `make` runs once they are,
    /// its work tracked by `registry` and a throw refused there.
    public func work(_ registry: ActionRegistry, _ make: @escaping @MainActor () throws -> ActionWork) throws -> ActionWork {
        let held = holds { [weak registry] in
            do { try registry?.track(make()) } catch { registry?.refuse(String(describing: error)) }
        }
        return held ? Task { nil } : try make()
    }

    /// Runs or drops the waiting open when its time came; true once none waits.
    private func advance() -> Bool {
        let windowOpen = !hadOrigin || origin.map { origin in openWindows().contains { $0 === origin } } == true
        guard let outcome = slot.step(ready: ready, windowOpen: windowOpen, now: now()) else { return !slot.isWaiting }
        expiry.cancel()
        watch?.cancel()
        watch = nil
        origin = nil
        switch outcome {
        case .run(let open): open()
        case .drop: show(RefusalStrings.pendingOpenDropped)
        }
        return true
    }
}

nonisolated extension RefusalStrings {
    /// A chat clicked while this Mac's sessions restore (``PendingSessionOpen``): it opens once they are ready.
    public static var pendingOpenWaits: String { text("refusal.daemon.pendingOpenWaits", "Opens when your sessions are restored.") }
    /// That chat's open was dropped: its window closed, or the sessions were not ready within 10 minutes.
    public static var pendingOpenDropped: String { text("refusal.daemon.pendingOpenDropped", "Stopped waiting to open the chat you clicked.") }
}
