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
/// task 016). The control socket binds off main and serves after the first
/// frame (task 019, `ControlLaunch`).
@MainActor
final class LaunchSettle {
    private(set) var isSettled = false
    private var unavailableWatch: Task<Void, Never>?
    /// The launch load-in: the pane region comes in on the first terminal
    /// frame, and everything shows if the daemon is unavailable.
    private let reveal: LaunchReveal
    /// The restore's and the visible panes' startup refs (p08-startup task 013), made at the root.
    let paneRefs: VisiblePaneRefs
    private var sawTerminalContent = false
    /// The agent pages' WebKit warm-up, whose empty page goes at the settle (``install(daemon:warmup:)``).
    private weak var warmup: AgentPageWarmup?

    /// - Parameters:
    ///   - reveal: The app's launch load-in (`AppServices.launchReveal`).
    ///   - paneRefs: The startup refs a terminal's content is a content signal for.
    init(reveal: LaunchReveal, paneRefs: VisiblePaneRefs) {
        self.reveal = reveal
        self.paneRefs = paneRefs
    }

    /// Settles (first call only).
    func settle() {
        guard !isSettled else { return }
        isSettled = true
        unavailableWatch?.cancel()
        unavailableWatch = nil
        // The agent pages' warm-up page goes; a warm-up still queued (afterStartup) runs later.
        warmup?.settle()
    }

    /// Listens for the first terminal content (`TerminalTimings`), for the
    /// pane region becoming ready any other way (a page or an agent shown
    /// first, `PaneController`; or the reveal deadline), and for the local
    /// daemon becoming unavailable.
    ///
    /// - Parameters:
    ///   - daemon: The local daemon.
    ///   - warmup: The agent pages' WebKit warm-up (`AppServices.agentPageWarmup`).
    func install(daemon: DaemonService, warmup: AgentPageWarmup) {
        self.warmup = warmup
        reveal.whenReady(.pane) { [weak self] in self?.settle() }
        TerminalTimings.onContentApplied = { [weak self] in self?.terminalContentApplied() }
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

    /// A terminal was handed content: a content signal for the visible pane refs while they hold
    /// startup; the first one also settles the launch once the frame showing it is committed. The
    /// hook stays installed while the refs hold startup, and goes at the first content after.
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
