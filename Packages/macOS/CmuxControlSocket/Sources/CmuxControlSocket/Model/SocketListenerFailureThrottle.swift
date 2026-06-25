public import Foundation

/// Per-key cooldown gate that decides whether a recurring socket-listener
/// failure should escalate from a breadcrumb to a captured error.
///
/// The host reports every listener failure through
/// ``SocketControlServerEvents/failure``; without throttling, a flapping
/// listener (for example a repeatedly missing socket path) would capture the
/// same error every few hundred milliseconds. This type remembers the last
/// capture time per `(message, stage, path, errno)` key and returns `true`
/// only when that key has not been captured within ``cooldown``.
///
/// Threading: the failure sink is a `@Sendable` closure invoked from the main
/// actor (lifecycle/recovery paths) and the listener queue (accept drain, path
/// monitor), so ``shouldCapture(message:stage:path:errnoCode:)`` must be safe to
/// call from any thread. State is guarded by an `NSLock` rather than an actor
/// because the caller is a synchronous, non-`async` callback that cannot await.
/// `@unchecked Sendable` is sound here: every access to the mutable
/// `lastCapturedAt` map is bracketed by `lock`/`unlock`.
public final class SocketListenerFailureThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastCapturedAt: [String: Date] = [:]
    private let cooldown: TimeInterval

    /// Creates a throttle.
    ///
    /// - Parameter cooldown: The minimum interval between captures of the same
    ///   failure key. Defaults to 60 seconds, matching the legacy app behavior.
    public init(cooldown: TimeInterval = 60) {
        self.cooldown = cooldown
    }

    /// Returns whether this failure should be captured now, recording the
    /// capture time when it returns `true`.
    ///
    /// - Parameters:
    ///   - message: The failure message.
    ///   - stage: The setup/recovery stage identifier.
    ///   - path: The socket path involved (empty string when unknown).
    ///   - errnoCode: The failing `errno`, if any.
    /// - Returns: `true` when the key has not been captured within ``cooldown``.
    public func shouldCapture(
        message: String,
        stage: String,
        path: String,
        errnoCode: Int32?
    ) -> Bool {
        let key = "\(message)|\(stage)|\(path)|\(errnoCode.map(String.init) ?? "none")"
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        if let lastCapturedAt = lastCapturedAt[key],
           now.timeIntervalSince(lastCapturedAt) < cooldown {
            return false
        }
        lastCapturedAt[key] = now
        return true
    }
}
