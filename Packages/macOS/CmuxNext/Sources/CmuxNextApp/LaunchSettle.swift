import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFeatures
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
/// task 016). Without the feature `controlSocketEarlyBind`, the control socket
/// still starts at ``settled(within:images:)``; with it, the socket binds on a
/// lane and serves after the first frame (task 019, `AppControl.postLaunch`).
@MainActor
final class LaunchSettle {
    private(set) var isSettled = false
    private var waiters: [@MainActor () -> Void] = []
    private var unavailableWatch: ServiceObservation<Bool>?
    /// The launch load-in: the pane region comes in on the first terminal
    /// frame, and everything shows if the daemon is unavailable.
    private let reveal: LaunchReveal
    /// The restore's and the visible panes' startup refs (p08-startup task 013), made at the root.
    let paneRefs: VisiblePaneRefs
    private var sawTerminalContent = false
    /// The clock of ``settled(within:images:)``'s limit.
    private let clock: any Clock<Duration>
    /// The agent pages' WebKit warm-up, whose empty page goes at the settle (``install(daemon:warmup:)``).
    private weak var warmup: AgentPageWarmup?

    /// - Parameters:
    ///   - reveal: The app's launch load-in (`AppServices.launchReveal`).
    ///   - paneRefs: The startup refs a terminal's content is a content signal for.
    ///   - clock: The clock of ``settled(within:images:)``'s limit (tests pass a manual one).
    init(reveal: LaunchReveal, paneRefs: VisiblePaneRefs, clock: any Clock<Duration> = ContinuousClock()) {
        self.reveal = reveal
        self.paneRefs = paneRefs
        self.clock = clock
    }

    /// Returns once the launch settled and no agent page waits behind its last
    /// frame, or after `limit` (a launch with no window never settles). With
    /// the daemon unavailable the launch settles at once, so only the launch
    /// images are waited for. The control socket starts here (cx-z9kz0) unless
    /// the feature `controlSocketEarlyBind` is on (`AppControl.postLaunch`).
    ///
    /// - Parameters:
    ///   - limit: The longest wait.
    ///   - images: The launch's image hold (`AppDelegate.launchImageHold`).
    func settled(within limit: Duration, images: LaunchImageHold) async {
        let (settled, done) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // timer-class-allow: one launch backstop that only finishes this stream; deleted with this wait once controlSocketEarlyBind ships on
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
        // The agent pages' warm-up page goes; a warm-up still queued (afterStartup) runs later.
        warmup?.settle()
        let waiting = waiters
        waiters = []
        for work in waiting { work() }
    }

    /// Runs `work` once, when the launch settled and no agent page waits behind its last frame (`images` clear,
    /// as ``settled(within:images:)`` waits), with no limit: the launch's reads of the last quit's frames go then.
    ///
    /// - Parameters:
    ///   - images: The launch's image hold (`AppDelegate.launchImageHold`).
    ///   - work: Runs on the main actor.
    func whenSettledAndClear(images: LaunchImageHold, _ work: @escaping @MainActor () -> Void) {
        whenSettled { images.whenClear(work) }
    }

    /// `memorySmallAppStores` (default off): once the launch settled and no agent pane draws its last page, the
    /// launch reads of the last quit's terminal frames and agent pages go, not at their 30 s deadline (p07-memory-083).
    ///
    /// - Parameters:
    ///   - frames: The last quit's terminal frames (`AppServices.terminalLaunchFrames`).
    ///   - pages: The last quit's agent pages (`AppServices.launchImages`, the agent tabs' store).
    ///   - features: The app's feature list.
    ///   - images: The launch's image hold (`AppDelegate.launchImageHold`).
    func dropLaunchReads(frames: TerminalLaunchFrames, pages: AgentPaneLaunchImages, features: FeatureList, images: LaunchImageHold) {
        guard features.isEnabled(.memorySmallAppStores) else { return }
        whenSettledAndClear(images: images) { [weak frames, weak pages] in
            frames?.dropLaunchRead()
            pages?.dropLaunchRead()
        }
    }

    private func whenSettled(_ work: @escaping @MainActor () -> Void) {
        if isSettled { work() } else { waiters.append(work) }
    }

    /// Listens for the first terminal content (`TerminalTimings`), for the
    /// pane region becoming ready any other way (a page or an agent shown
    /// first, `PaneController`; or the reveal deadline), and for the local
    /// daemon becoming unavailable.
    ///
    /// - Parameters:
    ///   - daemon: The local daemon.
    ///   - warmup: The agent pages' WebKit warm-up (`AppServices.agentPageWarmup`).
    ///   - mainWork: The app's main-thread scheduler: the daemon's startup state applies as a task on it.
    func install(daemon: DaemonService, warmup: AgentPageWarmup, on mainWork: MainWorkScheduler) {
        self.warmup = warmup
        reveal.whenReady(.pane) { [weak self] in self?.settle() }
        TerminalTimings.onContentApplied = { [weak self] in self?.terminalContentApplied() }
        // Ends when the daemon is unavailable or the launch settled (cancelled in settle). `visible`: it reveals
        // the window's regions.
        let watch = ServiceObservation(.visible, owner: "LaunchSettle.daemonUnavailable", on: mainWork) {
            daemon.startup.isUnavailable
        } apply: { [weak self] unavailable in
            guard unavailable, let self, !self.isSettled else { return }
            // No region will get its data: show everything as it is.
            self.reveal.markAllReady()
            self.settle()
        }
        if isSettled { watch.cancel() } else { unavailableWatch = watch }
    }

    /// A terminal was handed content: the visible pane refs read the panes again while they hold
    /// startup (a terminal pane is loaded-idle once it shows content and then gets none for
    /// `VisiblePaneRefs.quietPeriod`, p08-startup task 105); the first one also settles the launch once
    /// the frame showing it is committed. The hook stays installed while the refs hold startup, and goes
    /// at the first content after.
    func terminalContentApplied() {
        paneRefs.noteChange()
        if !paneRefs.isHolding { TerminalTimings.onContentApplied = nil }
        guard !sawTerminalContent else { return }
        sawTerminalContent = true
        DebugTimings.markLaunch("first_terminal_content_applied")
        // Ghostty presents on its own layer in this commit.
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { // main-proof: CATransaction.h: the completion block is called on the main thread
                DebugTimings.markLaunch("first_terminal_frame")
                self?.reveal.markReady(.pane)
                self?.settle()
            }
        }
    }
}
