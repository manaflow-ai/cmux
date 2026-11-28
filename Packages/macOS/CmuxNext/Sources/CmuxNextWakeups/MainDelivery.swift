import Foundation

/// Runs main-actor work from a callback whose thread the caller does not
/// control: KVO, a `queue: nil` notification, a completion handler or C
/// callback with no documented thread (plans/cmux-next/crash-elimination.md,
/// P1b). On the main thread the work runs inline, before `run` returns, so
/// the order of main-thread side effects is unchanged. Off the main thread
/// the work is enqueued on the main queue instead of trapping in
/// `MainActor.assumeIsolated`.
///
/// ```swift
/// observation = view.observe(\.frame) { @Sendable [weak self] _, _ in
///     MainDelivery().run { self?.layout() }
/// }
/// ```
public struct MainDelivery: Sendable {
    public init() {}

    /// Runs `work` now on the main thread, or on the main queue's next turn
    /// from any other thread.
    public func run(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            // main-proof: guarded by Thread.isMainThread above
            MainActor.assumeIsolated(work)
        } else {
            // main-proof: DispatchQueue.main runs its blocks on the main thread
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
    }
}
