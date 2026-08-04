/// Errors thrown by ``FixtureSyncTransport``.
public enum FixtureSyncTransportError: Error, Hashable, Sendable {
    /// No handler was registered for the requested method.
    case unhandledRequest(String)
}
