import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextWakeups
import Observation

/// Marks the startup phase's settle references the launch does not mark in one place
/// (p06-scheduler-007): the session restore, the visible page's first load, and all of them when
/// the daemon is unavailable, since none will come. Chrome's model: the `StartupObserver` of
/// `chrome/browser/after_startup_task_utils.cc` counts first paint, session restore and the
/// visible WebContents' load stopping before after-startup tasks run.
///
/// The app makes one at its composition root and keeps it; its watches end when startup settles.
@MainActor
public final class StartupReferences {
    /// Whether the visible page is still in its first load.
    public enum VisiblePage: Sendable, Equatable {
        /// The front pane has not shown its content yet, or shows a page whose first load runs.
        case waiting
        /// The front pane shows no page, or a page whose first load ended (or that loads nothing).
        case idle
    }

    /// Bumped when any tab's content is presented or released (``noteContentChange()``): what
    /// the front pane shows is not observable itself, so the visible-page read re-runs on it.
    /// Internal, not private: the `@Observable` macro's conformance extension must reach it.
    @MainActor @Observable
    final class ContentChanges {
        var count = 0
    }

    private let startup: StartupPhase
    private let reveal: LaunchReveal
    private let contentChanges = ContentChanges()
    private var unavailableWatch: Task<Void, Never>?
    private var visiblePageWatch: Task<Void, Never>?

    /// - Parameters:
    ///   - startup: The app's startup phase.
    ///   - reveal: The app's launch load-in: an unavailable daemon shows every region as it is.
    public init(startup: StartupPhase, reveal: LaunchReveal) {
        self.startup = startup
        self.reveal = reveal
        startup.whenReached(.settled) { [weak self] in self?.stop() }
    }

    /// Watches the local daemon until it is unavailable (or startup settles): then no snapshot,
    /// restore or page load will come, and every reference but the first frame is done; the
    /// regions show as they are, which is the frame (`LaunchReveal.markAllReady`).
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

    /// A tab's content was presented or released: the visible-page read runs again.
    public func noteContentChange() {
        guard visiblePageWatch != nil else { return }
        contentChanges.count &+= 1
    }

    /// Session restore finished: marks ``StartupPhase/Reference/restoreDone`` and waits for
    /// `visiblePage` (read again on each content change and on what it observes, such as the
    /// page's load state) to be idle.
    public func restored(visiblePage: @escaping @MainActor @Sendable () -> VisiblePage) {
        startup.markDone(.restoreDone)
        guard startup.pendingReferences.contains(.visiblePageIdle), visiblePageWatch == nil else { return }
        let changes = contentChanges
        // task-owner: self; ends when the visible page is idle, or cancelled when startup settles (stop)
        visiblePageWatch = Task { [weak self] in
            for await page in ObservationStream({ _ = changes.count; return visiblePage() }) where page == .idle {
                self?.visiblePageWatch = nil
                self?.startup.markDone(.visiblePageIdle)
                return
            }
        }
    }

    private func daemonUnavailable() {
        reveal.markAllReady()
        for reference in [StartupPhase.Reference.firstSnapshot, .restoreDone, .visiblePageIdle] { startup.markDone(reference) }
    }

    private func stop() {
        unavailableWatch?.cancel()
        unavailableWatch = nil
        visiblePageWatch?.cancel()
        visiblePageWatch = nil
    }
}
