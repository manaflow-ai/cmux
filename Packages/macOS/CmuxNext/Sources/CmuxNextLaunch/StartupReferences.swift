import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextWakeups
import Observation

/// Marks the startup phase's settle references when the daemon is unavailable (p06-scheduler-007),
/// since none of them will come then: the first snapshot, the session restore and the visible
/// page. Chrome's model: the `StartupObserver` of `chrome/browser/after_startup_task_utils.cc`
/// counts first paint, session restore and the visible WebContents' load stopping before
/// after-startup tasks run.
///
/// The restore and visible-page references of a launch that reaches its restore are marked by
/// ``VisiblePaneRefs`` (p08-startup task 013), their one owner. An unavailable daemon marks the
/// phase's references first and then releases the pane refs, so the phase's settle never comes
/// after the last startup ref and the completion reason is `daemonUnavailable`.
///
/// The app makes one at its composition root and keeps it; its watch ends when startup settles.
@MainActor
public final class StartupReferences {
    private let startup: StartupPhase
    private let reveal: LaunchReveal
    private let paneRefs: VisiblePaneRefs?
    private var unavailableWatch: Task<Void, Never>?

    /// - Parameters:
    ///   - startup: The app's startup phase.
    ///   - reveal: The app's launch load-in: an unavailable daemon shows every region as it is.
    ///   - paneRefs: The restore's and the visible panes' startup refs an unavailable daemon releases.
    public init(startup: StartupPhase, reveal: LaunchReveal, paneRefs: VisiblePaneRefs? = nil) {
        self.startup = startup
        self.reveal = reveal
        self.paneRefs = paneRefs
        startup.whenReached(.settled) { [weak self] in self?.stop() }
    }

    /// Watches the local daemon until it is unavailable (or startup settles): then no snapshot,
    /// restore or page load will come, and every reference but the first frame is done; the
    /// regions show as they are, which is the frame (`LaunchReveal.markAllReady`), and the startup
    /// refs of the restore and the visible panes are released.
    public func watchUnavailable(_ isUnavailable: @escaping @MainActor @Sendable () -> Bool) {
        guard startup.phase != .settled, unavailableWatch == nil else { return }
        // task-owner: self; ends at the first unavailable, or cancelled when startup settles (stop)
        unavailableWatch = Task { [weak self] in
            for await unavailable in ObservationStream(isUnavailable) where unavailable {
                self?.unavailableWatch = nil
                self?.daemonUnavailable()
                return
            }
        }
    }

    private func daemonUnavailable() {
        reveal.markAllReady()
        for reference in [StartupPhase.Reference.firstSnapshot, .restoreDone, .visiblePageIdle] { startup.markDone(reference) }
        paneRefs?.daemonUnavailable()
    }

    private func stop() {
        unavailableWatch?.cancel()
        unavailableWatch = nil
    }
}
