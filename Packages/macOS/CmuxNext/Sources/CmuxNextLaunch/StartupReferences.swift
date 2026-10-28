import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextWakeups

/// Marks the startup phase's settle references when the daemon is unavailable,
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
    private let mainWork: MainWorkScheduler
    private var unavailableWatch: ServiceObservation<Bool>?
    /// The daemon was heard unavailable: the references are marked, once.
    private var heardUnavailable = false

    /// - Parameters:
    ///   - startup: The app's startup phase.
    ///   - reveal: The app's launch load-in: an unavailable daemon shows every region as it is.
    ///   - mainWork: The launch's main-thread scheduler: a change of the daemon's state applies on it.
    ///   - paneRefs: The restore's and the visible panes' startup refs an unavailable daemon releases.
    public init(startup: StartupPhase, reveal: LaunchReveal, mainWork: MainWorkScheduler, paneRefs: VisiblePaneRefs? = nil) {
        self.startup = startup
        self.reveal = reveal
        self.mainWork = mainWork
        self.paneRefs = paneRefs
        startup.whenReached(.settled) { [weak self] in self?.stop() }
    }

    /// Watches the local daemon until it is unavailable (or startup settles): then no snapshot,
    /// restore or page load will come, and every reference but the first frame is done; the
    /// regions show as they are, which is the frame (`LaunchReveal.markAllReady`), and the startup
    /// refs of the restore and the visible panes are released. A daemon unavailable already is heard in this
    /// call. The change is a `visible` task: it reveals the regions.
    public func watchUnavailable(_ isUnavailable: @escaping @MainActor @Sendable () -> Bool) {
        guard startup.phase != .settled, !heardUnavailable, unavailableWatch == nil else { return }
        let watch = ServiceObservation(.visible, owner: "Startup.daemonUnavailable", on: mainWork,
                                       read: isUnavailable) { [weak self] unavailable in
            if unavailable { self?.daemonUnavailable() }
        }
        if !heardUnavailable { unavailableWatch = watch }
    }

    private func daemonUnavailable() {
        guard !heardUnavailable else { return }
        heardUnavailable = true
        stop()
        reveal.markAllReady()
        for reference in [StartupPhase.Reference.firstSnapshot, .restoreDone, .visiblePageIdle] { startup.markDone(reference) }
        paneRefs?.daemonUnavailable()
    }

    private func stop() {
        unavailableWatch?.cancel()
        unavailableWatch = nil
    }
}
