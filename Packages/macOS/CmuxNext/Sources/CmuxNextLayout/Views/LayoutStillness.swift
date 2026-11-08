public import CmuxNextWakeups

/// A window's layout as work kept out of a motion's frames sees it: whether a motion runs, and a keyed wait for its landing
/// (``LayoutRootView/whenStill(_:on:_:)``). Work nothing on screen needs (a parked page's build, the control snapshot)
/// waits for the landing instead of holding the main thread mid-slide (Leo 2026-11-04: the visible window comes first,
/// off-screen work is deferred). Tests stand in for it.
@MainActor
public protocol LayoutStillness: AnyObject {
    var isInLayoutMotion: Bool { get }
    func whenStill(_ key: String, on queue: FrameBatchQueue, _ work: @escaping @MainActor () -> Void)
}

extension LayoutRootView: LayoutStillness {}

extension LayoutStillness {
    /// True, with `work` queued once for the landing (a later call with the same `key` replaces it; it is dropped with
    /// the layout), when a motion runs now; false, queuing nothing, at rest.
    public func deferringWhileMoving(_ key: String, on queue: FrameBatchQueue, _ work: @escaping @MainActor () -> Void) -> Bool {
        guard isInLayoutMotion else { return false }
        whenStill(key, on: queue, work)
        return true
    }
}
