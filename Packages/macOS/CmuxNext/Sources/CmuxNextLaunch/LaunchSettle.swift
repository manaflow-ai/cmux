import CmuxNextCompat
public import CmuxNextDesign
import CmuxNextWakeups

/// One-shot launch event: the first live terminal frame is drawn (the
/// first terminal content reached a surface and the frame showing it
/// committed), or the daemon is unavailable so no terminal will draw.
///
/// Deferrable warm-up work waits for it, so it never runs in an idle
/// moment between the first window and its first terminal: the palette's
/// warm-up steps (15-40 ms each on the main thread) used to run there,
/// while the presentation scheduler waited one display frame to create the
/// first surface, and delayed that surface and its first frame. A launch
/// whose first window shows no terminal never settles; the palette then
/// does its first-open work when it first opens, as without warm-up.
@MainActor
public final class LaunchSettle {
    private var waiters: [@MainActor () -> Void] = []
    public private(set) var isSettled = false
    private var unavailableWatch: Task<Void, Never>?
    /// The launch load-in: the pane region comes in on the first terminal
    /// frame, and everything shows if the daemon is unavailable.
    private let reveal: LaunchReveal
    /// The agent panes' launch images: settled work waits until none is shown.
    private let imageHold: LaunchImageHold
    /// Runs once, when the launch settles, before the waiters.
    private let onSettle: @MainActor () -> Void

    /// - Parameters:
    ///   - reveal: The app's launch load-in (`AppServices.launchReveal`).
    ///   - imageHold: The agent panes' launch images (the app's one hold).
    ///   - onSettle: The app's own settle step (the agent pages' warm-up page is done).
    public init(reveal: LaunchReveal, imageHold: LaunchImageHold, onSettle: @escaping @MainActor () -> Void = {}) {
        self.reveal = reveal
        self.imageHold = imageHold
        self.onSettle = onSettle
    }

    /// Runs `work` once the launch settled and no agent page waits behind
    /// its last frame (at once when both hold).
    public func whenSettled(_ work: @escaping @MainActor () -> Void) {
        if isSettled { imageHold.whenClear(work) } else { waiters.append(work) }
    }

    /// Returns once `whenSettled` work would run, or after `limit` (a launch
    /// with no window never settles).
    public func settled(within limit: Duration) async {
        let (settled, done) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let backstop = DemandTimer(owner: "LaunchSettle.settled")
        backstop.schedule(after: limit) { done.finish() }
        whenSettled { done.finish() }
        for await _ in settled {}
        backstop.cancel()
    }

    /// Settles (first call only) and runs the waiters in order.
    public func settle() {
        guard !isSettled else { return }
        isSettled = true
        unavailableWatch?.cancel()
        unavailableWatch = nil
        onSettle()
        let waiting = waiters
        waiters.removeAll()
        // An agent page still loading behind its last frame paints first (LaunchImageHold).
        imageHold.whenClear { for work in waiting { work() } }
    }

    /// The first live terminal frame committed: the pane region is ready and the launch settles.
    public func firstTerminalFrame() {
        reveal.markReady(.pane)
        settle()
    }

    /// Listens for the pane region becoming ready any other way (a page or an
    /// agent shown first, `PaneController`; or the reveal deadline), and for
    /// the local daemon becoming unavailable.
    public func install(isUnavailable: @escaping @MainActor @Sendable () -> Bool) {
        reveal.whenReady(.pane) { [weak self] in self?.settle() }
        // task-owner: ends when the daemon is unavailable or the launch settled (cancelled in settle)
        unavailableWatch = Task { [weak self] in
            for await unavailable in ObservationStream(isUnavailable) where unavailable {
                // No region will get its data: show everything as it is.
                self?.reveal.markAllReady()
                self?.settle()
                return
            }
        }
    }
}
