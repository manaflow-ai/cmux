/// An injectable clock for the updater's bounded, cancellable delays (check timeout,
/// "no updates" auto-dismiss, install watchdog, wake check, readiness retry, relaunch recheck).
///
/// Production uses ``SystemUpdateClock`` (a real `Task.sleep`); tests inject a fake that
/// returns immediately or coordinates timing, so delay-driven behavior is verified with no
/// real waiting. The delays this clock drives are *intended* delays, never a poll or a
/// "let state settle" hack.
public protocol UpdateClock: Sendable {
    /// Suspends for `duration`, ending up to `tolerance` late so the kernel can coalesce the wake
    /// with others (`nil` lets the system choose), and throws `CancellationError` if the
    /// surrounding task is cancelled first.
    func sleep(for duration: Duration, tolerance: Duration?) async throws
}

/// The production ``UpdateClock``, backed by `Task.sleep`.
public struct SystemUpdateClock: UpdateClock {
    /// Creates a system clock.
    public init() {}

    public func sleep(for duration: Duration, tolerance: Duration?) async throws {
        // wakeup-allow: deadline the UpdateClock seam; each caller passes its leeway and escapes its own shape
        try await Task.sleep(for: duration, tolerance: tolerance)
    }
}
