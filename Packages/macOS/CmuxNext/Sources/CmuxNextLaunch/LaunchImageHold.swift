public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// The agent panes drawing their last page while the live page loads (`showLaunchImage`), as one
/// startup ref (p08-startup task 016): while any image shows, the launch's ``StartupScheduler`` is
/// not complete, so its afterStartup work (the palette's warm-up steps, the icon picker, the open
/// panel) waits until every image went. A step run at the first idle moment held the main thread
/// just as WebKit needed it to start the page's navigation (about 70 ms on a cold launch, cx-z9kz0).
/// Chrome holds startup open the same way until the visible pages loaded (`StartupObserver`,
/// chrome/browser/after_startup_task_utils.cc).
///
/// Each shown image owns a ``Share``: it ends once, when the image's page paints, at the image's
/// limit (``imageLimit``), or when its pane leaves the window or is torn down, so a pane closed
/// during launch never holds startup to the failsafe. After startup completed the hold takes no ref.
///
/// The app makes one at its composition root with its scheduler and passes it to the panes;
/// tests make their own.
///
/// ```swift
/// let images = LaunchImageHold(startup: order.startup)
/// let share = images.began()             // a pane shows its last page
/// share.end(.visiblePaneLoadedIdle)      // its live page painted
/// ```
@MainActor
public final class LaunchImageHold {
    /// How long a launch image holds startup when its page never reports a first frame. An image standing in for
    /// a page that has not painted stays past it (`launchImageMayClear`, #24262); only its share of the hold ends
    /// then, so what bounds the wait for deferred work is this limit, not the image.
    public static let imageLimit: Duration = .seconds(3)

    /// One shown image's part of the hold; ``end(_:)`` ends it once.
    @MainActor
    public final class Share {
        private var hold: LaunchImageHold?

        fileprivate init(_ hold: LaunchImageHold) {
            self.hold = hold
        }

        /// Whether the share still counts in its hold.
        public var isActive: Bool { hold != nil }

        /// The image went: its page painted (`visiblePaneLoadedIdle`), its limit passed
        /// (`visiblePaneTimedOut`), or its pane shows another tab or left the window
        /// (`noVisiblePane`). Later calls do nothing.
        public func end(_ reason: StartupInProgressRef.Reason) {
            guard let hold else { return }
            self.hold = nil
            hold.ended(reason)
        }
    }

    private let startup: StartupScheduler?
    private var shown = 0
    private var ref: StartupInProgressRef?
    /// ``whenClear(_:)`` work, run when the last image goes or startup completes.
    private var clearWaiters: [@MainActor () -> Void] = []

    /// - Parameter startup: The launch's scheduler (its ref is held while an image shows); nil holds nothing.
    public init(startup: StartupScheduler? = nil) {
        self.startup = startup
    }

    /// True while at least one launch image is shown.
    public var isHolding: Bool { shown > 0 }

    /// A pane put up its launch image; the first one holds startup.
    ///
    /// - Returns: The image's share; end it when the image goes.
    public func began() -> Share {
        shown += 1
        if shown == 1 { ref = startup?.hold("LaunchImageHold.images") }
        return Share(self)
    }

    /// An image's share ended; the last one ends the hold with its reason.
    private func ended(_ reason: StartupInProgressRef.Reason) {
        guard shown > 0 else { return }
        shown -= 1
        guard shown == 0 else { return }
        ref?.release(reason)
        ref = nil
        runClearWaiters()
    }

    /// Runs `work` once no agent page waits behind its last frame, or startup completed (at once when
    /// either holds, and with no scheduler at once too).
    public func whenClear(_ work: @escaping @MainActor () -> Void) {
        guard shown > 0, let startup, startup.completion == nil else { return work() }
        clearWaiters.append(work)
        guard clearWaiters.count == 1 else { return }
        // The failsafe ends the wait of an image that never ends with the launch.
        startup.whenComplete { [weak self] _ in self?.runClearWaiters() }
    }

    /// Returns when ``whenClear(_:)`` work would run, or when that work was dropped unrun.
    public func clear() async {
        _ = try? await withOnceContinuation { (done: OnceContinuation<Void, OnceContinuationError>) in
            whenClear { done.resume(returning: ()) }
        }
    }

    private func runClearWaiters() {
        let waiting = clearWaiters
        clearWaiters = []
        for work in waiting { work() }
    }
}
