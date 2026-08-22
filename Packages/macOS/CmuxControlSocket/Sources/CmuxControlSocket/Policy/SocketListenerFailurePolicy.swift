public import Foundation

/// Bounds Sentry captures for repeated listener-start failures.
///
/// A listener can be asked to start again by several independent lifecycle
/// paths while the same socket path is unavailable. Those attempts remain
/// useful breadcrumbs, but an error event for every attempt is operational
/// noise. The policy is deliberately stateless so the app can keep its
/// existing lock-guarded last-capture map without coupling telemetry state to
/// the listener state machine.
public struct SocketListenerFailurePolicy: Sendable {
    /// Minimum interval between captures for one listener-failure key.
    public let captureCooldown: TimeInterval

    /// Creates a listener-failure sampling policy.
    ///
    /// - Parameter captureCooldown: Minimum interval between captures. Values
    ///   below zero normalize to zero for deterministic callers and tests.
    public init(captureCooldown: TimeInterval = 3_600) {
        self.captureCooldown = max(0, captureCooldown)
    }

    /// Returns whether a failure should become a Sentry event.
    ///
    /// - Parameters:
    ///   - lastCapturedAt: The previous capture time for the same key.
    ///   - now: The current wall-clock time.
    /// - Returns: `true` for the first failure or once the cooldown has elapsed.
    public func shouldCapture(lastCapturedAt: Date?, now: Date) -> Bool {
        guard let lastCapturedAt else { return true }
        return now.timeIntervalSince(lastCapturedAt) >= captureCooldown
    }
}
