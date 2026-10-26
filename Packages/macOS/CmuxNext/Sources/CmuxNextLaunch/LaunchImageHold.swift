public import CmuxNextWakeups

/// The agent panes drawing their last page while the live page loads
/// (`showLaunchImage`). Deferred launch work (`LaunchSettle`: the palette's
/// warm-up steps) waits until none is left: a step run at the first idle
/// moment held the main thread just as WebKit needed it to start the page's
/// navigation (about 70 ms on a cold launch, cx-z9kz0). Each image goes when
/// its page paints, or at its limit (``imageLimit``).
@MainActor
public final class LaunchImageHold {
    /// How long a launch image may stay when its page never reports a first frame.
    public static let imageLimit: Duration = .seconds(3)

    private var shown = 0
    private var waiters: [@MainActor () -> Void] = []
    /// A pane that went away with its image up never ends it: the waiters run by then anyway.
    private let backstop: DemandTimer

    /// - Parameter backstop: The deadline that runs the waiters when an image
    ///   never ends; tests inject a manual clock.
    public init(backstop: DemandTimer = DemandTimer(owner: "LaunchImageHold.backstop")) {
        self.backstop = backstop
    }

    /// True while at least one launch image is shown.
    public var isHolding: Bool { shown > 0 }

    /// A pane put up its launch image.
    public func began() {
        shown += 1
    }

    /// A pane took its launch image down; the last one runs the waiters.
    public func ended() {
        shown = max(0, shown - 1)
        guard shown == 0 else { return }
        flush()
    }

    private func flush() {
        backstop.cancel()
        let waiting = waiters
        waiters.removeAll()
        for work in waiting { work() }
    }

    /// Returns once no agent page waits behind its last frame (at once when none does).
    public func clear() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in whenClear { done.resume() } }
    }

    /// Runs `work` once no launch image is shown (at once when none is).
    public func whenClear(_ work: @escaping @MainActor () -> Void) {
        guard shown > 0 else { return work() }
        waiters.append(work)
        backstop.schedule(after: Self.imageLimit + .seconds(1)) { @MainActor [weak self] in self?.flush() }
    }
}
