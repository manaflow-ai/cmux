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
/// task 016).
@MainActor
final class LaunchSettle {
    private(set) var isSettled = false
    private var unavailableWatch: Task<Void, Never>?
    /// The launch load-in: the pane region comes in on the first terminal
    /// frame, and everything shows if the daemon is unavailable.
    private let reveal: LaunchReveal

    /// - Parameter reveal: The app's launch load-in (`AppServices.launchReveal`).
    init(reveal: LaunchReveal) {
        self.reveal = reveal
    }

    /// Settles (first call only).
    func settle() {
        guard !isSettled else { return }
        isSettled = true
        unavailableWatch?.cancel()
        unavailableWatch = nil
        // The agent pages' warm-up page is done: their first page made its own process by now.
        AgentPaneView.finishWarmup()
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
