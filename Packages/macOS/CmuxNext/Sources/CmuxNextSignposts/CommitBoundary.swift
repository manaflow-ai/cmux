public import CoreFoundation

/// Runs work once, right after the Core Animation commit of the current main run-loop turn.
///
/// Core Animation commits the turn's layer changes from a main run-loop observer (before
/// waiting, and on exit) at order 2,000,000. A one-shot observer at the next order runs after
/// that commit, so it marks the end of the frame an action produced: a real signal, no sleep, no
/// timer. Nothing is installed between calls.
///
/// ```swift
/// let interval = Signposter.action.begin(.actionCommit, "id=tab.new")
/// CommitBoundary().after { Signposter.action.end(.actionCommit, interval) }
/// ```
public struct CommitBoundary: Sendable {
    /// The observer order: one after Core Animation's commit observer.
    static let order: CFIndex = 2_000_001

    /// A boundary on the main run loop.
    public init() {}

    /// Runs `body` once, after the Core Animation commit that ends this main run-loop turn.
    ///
    /// - Parameter body: Main-actor work; it runs in the same turn, before the run loop waits.
    @MainActor
    public func after(_ body: @escaping @MainActor () -> Void) {
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, false, Self.order) { _, _ in
            // main-proof: the observer is added to the main run loop only (below).
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
    }
}
