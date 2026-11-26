internal import os

/// Decides which listener failures escalate from a breadcrumb to a captured
/// Sentry error.
///
/// A permanently wedged machine restarts its listener on every wake and
/// activation, so a time-based cooldown still produces an unbounded event
/// stream (a 60s cooldown yielded ~1400 events/day per machine on
/// CMUXTERM-MACOS-2MHE). Instead, each distinct failure key
/// (message|stage|path|errno) is captured once per failure episode: the seen
/// set clears when the listener starts successfully, so a recovered listener
/// that later fails again reports the new episode, while a listener that
/// never recovers reports each distinct failure exactly once per app session.
///
/// `socket.listener.path.missing` can additionally be demoted to
/// breadcrumb-only: on debug builds, cleanup scripts routinely delete `/tmp`
/// dev sockets and the path monitor self-heals by restarting the listener,
/// so that state is expected rather than an error (CMUXTERM-MACOS-KBT).
///
/// Thread-safe; the failure seam is invoked from the main actor and the
/// listener queue.
public final class SocketListenerFailureCaptureGate: Sendable {
    /// The failure message the path monitor reports for a deleted socket file.
    public static let pathMissingMessage = "socket.listener.path.missing"

    private let capturesPathMissingFailures: Bool
    private let capturedKeys = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// Creates a gate.
    ///
    /// - Parameter capturesPathMissingFailures: Whether
    ///   ``pathMissingMessage`` failures may be captured at all. Pass `false`
    ///   for debug-like bundle identifiers, where deleted dev sockets are
    ///   expected and the monitor self-heals.
    public init(capturesPathMissingFailures: Bool = true) {
        self.capturesPathMissingFailures = capturesPathMissingFailures
    }

    /// Whether this failure should be captured (the breadcrumb is always
    /// recorded by the caller). True at most once per distinct key per
    /// failure episode.
    ///
    /// - Parameters:
    ///   - message: The failure message (e.g. `socket.listener.start.failed`).
    ///   - stage: The failing stage.
    ///   - path: The socket path involved.
    ///   - errnoCode: The failing `errno`, when known.
    public func shouldCapture(
        message: String,
        stage: String,
        path: String,
        errnoCode: Int32?
    ) -> Bool {
        if message == Self.pathMissingMessage, !capturesPathMissingFailures {
            return false
        }
        let key = "\(message)|\(stage)|\(path)|\(errnoCode.map(String.init) ?? "none")"
        return capturedKeys.withLock { $0.insert(key).inserted }
    }

    /// Marks the end of a failure episode: the listener started successfully,
    /// so any later failure is a new incident worth one capture.
    public func listenerDidStart() {
        capturedKeys.withLock { $0.removeAll() }
    }
}
