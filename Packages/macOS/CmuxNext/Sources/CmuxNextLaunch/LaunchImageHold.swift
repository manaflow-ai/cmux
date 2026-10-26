public import CmuxNextWakeups

/// The agent panes drawing their last page while the live page loads (`showLaunchImage`), as one
/// startup ref (p08-startup task 016): while any image shows, the launch's ``StartupScheduler`` is
/// not complete, so its afterStartup work (the palette's warm-up steps, the icon picker, the open
/// panel) waits until every image went. A step run at the first idle moment held the main thread
/// just as WebKit needed it to start the page's navigation (about 70 ms on a cold launch, cx-z9kz0).
/// Chrome holds startup open the same way until the visible pages loaded (`StartupObserver`,
/// chrome/browser/after_startup_task_utils.cc).
///
/// Each image goes when its page paints, or at its limit (``imageLimit``); a pane that went away
/// with its image up leaves the ref held until the scheduler's failsafe, which records it as
/// `failsafe` instead of hiding it. After startup completed the hold takes no ref.
///
/// The app makes one at its composition root with its scheduler and passes it to the panes;
/// tests make their own.
///
/// ```swift
/// let images = LaunchImageHold(startup: order.startup)
/// images.began()                          // a pane shows its last page
/// images.ended(.visiblePaneLoadedIdle)    // its live page painted
/// ```
@MainActor
public final class LaunchImageHold {
    /// How long a launch image may stay when its page never reports a first frame.
    public static let imageLimit: Duration = .seconds(3)

    private let startup: StartupScheduler?
    private var shown = 0
    private var ref: StartupInProgressRef?
    /// ``clear()`` callers, resumed when the last image goes or startup completes.
    private var clearWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter startup: The launch's scheduler (its ref is held while an image shows); nil holds nothing.
    public init(startup: StartupScheduler? = nil) {
        self.startup = startup
    }

    /// True while at least one launch image is shown.
    public var isHolding: Bool { shown > 0 }

    /// A pane put up its launch image; the first one holds startup.
    public func began() {
        shown += 1
        guard shown == 1 else { return }
        ref = startup?.hold("LaunchImageHold.images")
    }

    /// A pane took its launch image down; the last one ends the hold.
    ///
    /// - Parameter reason: Why the image went: its page painted (`visiblePaneLoadedIdle`), its
    ///   limit passed (`visiblePaneTimedOut`), or the pane shows another tab (`noVisiblePane`).
    public func ended(_ reason: StartupInProgressRef.Reason = .visiblePaneLoadedIdle) {
        guard shown > 0 else { return }
        shown -= 1
        guard shown == 0 else { return }
        ref?.release(reason)
        ref = nil
        resumeClearWaiters()
    }

    /// Returns once no agent page waits behind its last frame, or startup completed (at once when
    /// either holds, and with no scheduler at once too).
    public func clear() async {
        guard shown > 0, let startup, startup.completion == nil else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            clearWaiters.append(done)
            guard clearWaiters.count == 1 else { return }
            // The failsafe ends a lost image's wait with the launch.
            startup.whenComplete { [weak self] _ in self?.resumeClearWaiters() }
        }
    }

    private func resumeClearWaiters() {
        let waiting = clearWaiters
        clearWaiters = []
        for waiter in waiting { waiter.resume() }
    }
}
