/// Why ``AsyncProcess/run(_:)`` has no outcome. A cancelled caller gets `CancellationError` instead.
public enum ProcessFailure: Error, Sendable, Equatable {
    /// The program could not start (missing, not executable, a bad directory); the system's message.
    case launch(String)
    /// It ran past the request's timeout; it was sent the request's stop signal.
    case timedOut
}
