import CmuxNextWakeups

/// The agent panes drawing their last page while the live page loads
/// (`showLaunchImage`). Deferred launch work (`LaunchSettle`: the palette's
/// warm-up steps) waits until none is left: a step run at the first idle
/// moment held the main thread just as WebKit needed it to start the page's
/// navigation (about 70 ms on a cold launch, cx-z9kz0). An image goes when its
/// page paints; one standing in for a page that has not painted stays past
/// `paneLaunchImageLimit` (`launchImageMayClear`), so what bounds the wait for
/// deferred work is the backstop below, not the image.
@MainActor
final class LaunchImageHold {
    static let shared = LaunchImageHold()
    private var shown = 0
    private var waiters: [@MainActor () -> Void] = []
    /// A pane that went away with its image up never ends it: the waiters run by then anyway.
    private let backstop = DemandTimer(owner: "LaunchImageHold.backstop")

    func began() {
        shown += 1
    }

    func ended() {
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
    func clear() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in whenClear { done.resume() } }
    }

    /// Runs `work` once no launch image is shown (at once when none is).
    func whenClear(_ work: @escaping @MainActor () -> Void) {
        guard shown > 0 else { return work() }
        waiters.append(work)
        backstop.schedule(after: paneLaunchImageLimit + .seconds(1)) { @MainActor [weak self] in self?.flush() }
    }
}
