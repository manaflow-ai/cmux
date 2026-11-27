import CmuxNextWakeups

/// Holds an overlay panel's reveal until its page is ready, so a page made by the open itself (no earlier sign of
/// intent warmed it) never shows as a blank card that fills in later: the panel stays off screen until the page has
/// drawn, then shows in one step, as a warm page does. A page that is not ready after the limit is shown as it is.
/// One reveal waits at a time: a new ``hold(ready:limit:_:)`` or a ``cancel()`` drops the one waiting.
@MainActor
public final class PageRevealGate {
    private var pending: (() -> Void)?
    private let deadline: DemandTimer

    public init(owner: String) {
        deadline = DemandTimer(owner: owner)
    }

    /// Whether a reveal waits for its page.
    public var isHolding: Bool { pending != nil }

    /// Runs `reveal` now when `ready`, else at the next ``open()`` or after `limit`, whichever is first.
    public func hold(ready: Bool, limit: Duration, _ reveal: @escaping () -> Void) {
        cancel()
        guard !ready else { return reveal() }
        pending = reveal
        deadline.schedule(after: limit) { @MainActor [weak self] in self?.open() }
    }

    /// The page is ready: the waiting reveal runs now.
    public func open() {
        deadline.cancel()
        let reveal = pending
        pending = nil
        reveal?()
    }

    /// Drops the waiting reveal (the open ended before its page was ready).
    public func cancel() {
        deadline.cancel()
        pending = nil
    }
}
