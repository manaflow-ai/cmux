import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextTerminal
import CmuxNextWakeups

/// One-shot launch event: the first live terminal frame is drawn (the
/// first terminal content reached a surface and the frame showing it
/// committed), or the daemon is unavailable so no terminal will draw. It
/// reveals the pane region and ends the agent pages' warm-up page.
///
/// Deferrable warm-up work (the palette's steps, 15-40 ms each on the main
/// thread) is an afterStartup post of the launch's `StartupScheduler`, which
/// completes only once the visible page loaded and the launch images went, so
/// it never runs between the first window and its first content (p08-startup
/// task 016). The control socket still starts at ``settled(within:images:)``
/// until task 019 binds it off main.
@MainActor
final class LaunchSettle {
    private(set) var isSettled = false
    private var waiters: [@MainActor () -> Void] = []
    private var unavailableWatch: Task<Void, Never>?
    /// The launch load-in: the pane region comes in on the first terminal
    /// frame, and everything shows if the daemon is unavailable.
    private let reveal: LaunchReveal
    /// The clock of ``settled(within:images:)``'s limit.
    private let clock: any Clock<Duration>

    /// - Parameters:
    ///   - reveal: The app's launch load-in (`AppServices.launchReveal`).
    ///   - clock: The clock of ``settled(within:images:)``'s limit (tests pass a manual one).
    init(reveal: LaunchReveal, clock: any Clock<Duration> = ContinuousClock()) {
        self.reveal = reveal
        self.clock = clock
    }

    /// Returns once the launch settled and no agent page waits behind its last
    /// frame, or after `limit` (a launch with no window never settles). With
    /// the daemon unavailable the launch settles at once, so only the launch
    /// images are waited for. The control socket starts here (cx-z9kz0).
    ///
    /// - Parameters:
    ///   - limit: The longest wait.
    ///   - images: The launch's image hold (`AppDelegate.launchImageHold`).
    func settled(within limit: Duration, images: LaunchImageHold) async {
        let (settled, done) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // timer-class-allow: one launch backstop that only finishes this stream; task 019 deletes it with this wait
        let backstop = DemandTimer(owner: "LaunchSettle.settled", clock: clock)
        backstop.schedule(after: limit) { done.finish() }
        whenSettled { images.whenClear { done.finish() } }
        for await _ in settled {}
        backstop.cancel()
    }

    /// Settles (first call only) and runs the ``settled(within:images:)`` waiters.
    func settle() {
        guard !isSettled else { return }
        isSettled = true
        unavailableWatch?.cancel()
        unavailableWatch = nil
        // The agent pages' warm-up page is done: their first page made its own process by now.
        AgentPaneView.finishWarmup()
        let waiting = waiters
        waiters = []
        for work in waiting { work() }
    }

    private func whenSettled(_ work: @escaping @MainActor () -> Void) {
        if isSettled { work() } else { waiters.append(work) }
    }

    /// Listens for the first terminal content (`TerminalTimings`), for the
    /// pane region becoming ready any other way (a page or an agent shown
    /// first, `PaneController`; or the reveal deadline), and for the local
    /// daemon becoming unavailable.
    func install(daemon: DaemonService) {
        reveal.whenReady(.pane) { [weak self] in self?.settle() }
        TerminalTimings.onContentApplied = { [weak self] in
            TerminalTimings.onContentApplied = nil
            DebugTimings.markLaunch("first_terminal_content_applied")
            // Ghostty presents on its own layer in this commit.
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated { // main-proof: CATransaction.h: the completion block is called on the main thread
                    DebugTimings.markLaunch("first_terminal_frame")
                    self?.reveal.markReady(.pane)
                    self?.settle()
                }
            }
        }
        // task-owner: ends when the daemon is unavailable or the launch settled (cancelled in settle)
        unavailableWatch = Task { [weak self] in
            for await unavailable in ObservationStream({ daemon.startup.isUnavailable }) where unavailable {
                // No region will get its data: show everything as it is.
                self?.reveal.markAllReady()
                self?.settle()
                return
            }
        }
    }
}
