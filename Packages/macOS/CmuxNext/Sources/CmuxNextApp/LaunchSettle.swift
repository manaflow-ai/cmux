import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextTerminal
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
///
/// It never settles before the first window frame is committed
/// (`FirstFrameGate`): a page or an agent shown first makes the pane region
/// ready while `applicationDidFinishLaunching` still builds the window, and
/// the deferred work then delayed that frame by about 33 ms (REOPEN-F7).
@MainActor
final class LaunchSettle {
    private var waiters: [@MainActor () -> Void] = []
    private(set) var isSettled = false
    /// `settle` was called; the launch settles at the first window frame.
    private var settleAsked = false
    private var unavailableWatch: Task<Void, Never>?
    /// The launch load-in: the pane region comes in on the first terminal
    /// frame, and everything shows if the daemon is unavailable.
    private let reveal: LaunchReveal
    /// The first window frame (`AppDelegate.firstFrame`).
    private let firstFrame: FirstFrameGate
    /// The agent pages still drawing their last page (tests pass their own).
    private let imageHold: LaunchImageHold

    init(reveal: LaunchReveal = .shared, firstFrame: FirstFrameGate, imageHold: LaunchImageHold = .shared) {
        self.reveal = reveal
        self.firstFrame = firstFrame
        self.imageHold = imageHold
    }

    /// Runs `work` once the launch settled and no agent page waits behind
    /// its last frame (at once when both hold).
    func whenSettled(_ work: @escaping @MainActor () -> Void) {
        if isSettled { imageHold.whenClear(work) } else { waiters.append(work) }
    }

    /// Returns once `whenSettled` work would run, or after `limit` (a launch
    /// with no window never settles).
    func settled(within limit: Duration) async {
        let (settled, done) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let backstop = DemandTimer(owner: "LaunchSettle.settled")
        backstop.schedule(after: limit) { done.finish() }
        whenSettled { done.finish() }
        for await _ in settled {}
        backstop.cancel()
    }

    /// Settles (first call only) once the first window frame is committed (at once after it), and runs the
    /// waiters in order.
    func settle() {
        guard !settleAsked else { return }
        settleAsked = true
        unavailableWatch?.cancel()
        unavailableWatch = nil
        // The agent pages' warm-up page is not needed: their first page made its own process by now. Here, not at
        // the first window frame: the warm-up starts at that frame (`startLaterTabWarmups`), and must see this first.
        AgentPaneView.finishWarmup()
        firstFrame.whenOpen { [weak self] in self?.finishSettle() }
    }

    private func finishSettle() {
        isSettled = true
        let waiting = waiters
        waiters.removeAll()
        // An agent page still loading behind its last frame paints first (LaunchImageHold).
        imageHold.whenClear { for work in waiting { work() } }
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
