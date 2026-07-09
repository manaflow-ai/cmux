public import Foundation

/// Deduplicates socket-listener failure captures so an identical failure does
/// not flood error telemetry while a problem persists.
///
/// The failure callback wired into ``SocketControlServerEvents`` fires on the
/// listener's nonisolated lane and cannot await, so this throttle keeps a tiny
/// `message|stage|path|errnoCode` → last-capture-time map behind an `NSLock`.
/// ``shouldCapture(message:stage:path:errnoCode:)`` returns `true` the first
/// time a key is seen and again only after ``cooldown`` seconds have elapsed.
///
/// A single instance is held per socket router (one router per process today,
/// matching the former process-wide static that this type replaces). The
/// cooldown is constructor-injected so tests can drive the dedupe window
/// deterministically.
public final class SocketListenerFailureCaptureThrottle: @unchecked Sendable {
    /// Minimum interval between captures of the same failure key.
    private let cooldown: TimeInterval
    /// Guards ``lastCapturedAt`` for the synchronous nonisolated failure lane.
    private let lock = NSLock()
    /// Last capture time per `message|stage|path|errnoCode` key.
    private var lastCapturedAt: [String: Date] = [:]

    /// Creates a throttle.
    ///
    /// - Parameter cooldown: Minimum seconds between captures of the same
    ///   failure key. Defaults to 60 seconds.
    public init(cooldown: TimeInterval = 60) {
        self.cooldown = cooldown
    }

    /// Decides whether a failure should be captured now or suppressed as a
    /// duplicate within the cooldown window.
    ///
    /// - Parameters:
    ///   - message: The failure message.
    ///   - stage: The stable identifier of the failing setup stage.
    ///   - path: The socket path involved in the failure.
    ///   - errnoCode: The `errno` reported by the failing call, if any.
    /// - Returns: `true` if this failure key has not been captured within the
    ///   last ``cooldown`` seconds (and records the capture time); `false`
    ///   otherwise.
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
