import AppKit
import CmuxNextTerminal

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
final class LaunchSettle {
    private var waiters: [@MainActor () -> Void] = []
    private(set) var isSettled = false
    private var unavailableWatch: Task<Void, Never>?

    /// Runs `work` once the launch settled (at once when it has).
    func whenSettled(_ work: @escaping @MainActor () -> Void) {
        if isSettled { work() } else { waiters.append(work) }
    }

    /// Settles (first call only) and runs the waiters in order.
    func settle() {
        guard !isSettled else { return }
        isSettled = true
        unavailableWatch?.cancel()
        unavailableWatch = nil
        let waiting = waiters
        waiters.removeAll()
        for work in waiting { work() }
    }

    /// Listens for the first terminal content (`TerminalTimings`) and for
    /// the local daemon becoming unavailable.
    func install(daemon: DaemonService) {
        TerminalTimings.onContentApplied = { [weak self] in
            TerminalTimings.onContentApplied = nil
            DebugTimings.markLaunch("first_terminal_content_applied")
            // Ghostty presents on its own layer in this commit.
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated {
                    DebugTimings.markLaunch("first_terminal_frame")
                    self?.settle()
                }
            }
        }
        // task-owner: ends when the daemon is unavailable or the launch settled (cancelled in settle)
        unavailableWatch = Task { [weak self] in
            for await unavailable in Observations({ daemon.startup.isUnavailable }) where unavailable {
                self?.settle()
                return
            }
        }
    }
}
