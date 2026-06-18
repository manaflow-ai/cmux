import Foundation

/// An injectable clock for a watcher's leading-edge coalescing delay.
///
/// A ``RecursivePathWatcher`` coalesces a burst of filesystem events into a
/// single yield by arming one bounded delay on the first event of a window and
/// ignoring further events until it fires. That delay is an *intended* rate
/// limit, never a poll or a "let things settle" hack, so it is driven through
/// this seam rather than a raw timer.
///
/// Production uses ``SystemFileWatchClock`` (a real `Task.sleep`). Tests inject a
/// fake that suspends until released, so the coalescing behavior is verified
/// deterministically with no real waiting.
///
/// ```swift
/// let watcher = RecursivePathWatcher(paths: paths, clock: SystemFileWatchClock())
/// ```
public protocol FileWatchClock: Sendable {
    /// Suspends for `duration`, throwing `CancellationError` if the surrounding
    /// task is cancelled first.
    ///
    /// - Parameter duration: How long to suspend before resuming.
    func sleep(for duration: Duration) async throws
}

/// The production ``FileWatchClock``, backed by `Task.sleep`.
public struct SystemFileWatchClock: FileWatchClock {
    /// Creates a system clock.
    public init() {}

    public func sleep(for duration: Duration) async throws {
        // Bounded, cancellable, intended throttle delay behind the clock seam
        // (modern-concurrency policy carve-out): coalesce a filesystem-event burst
        // into one yield. Cancelled when the watcher stops.
        try await Task.sleep(for: duration)
    }
}
