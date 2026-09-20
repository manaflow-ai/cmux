/// Failures from the cmux protocol-12 JSON-lines compatibility client.
public enum MobileRemoteCmuxProtocolError: Error, Equatable, Sendable {
    /// The SSH session ended before a complete JSON line arrived.
    case unexpectedEOF
    /// A single JSON line exceeded the configured limit.
    case frameTooLarge
    /// A line was not valid JSON or did not have the expected object shape.
    case malformedFrame
    /// A response did not match the request identifier.
    case responseIDMismatch
    /// The cmux server rejected a request.
    case server(String)
    /// The endpoint was not a cmux-tui protocol-12 server.
    case incompatibleServer
    /// Two requests were attempted concurrently on the ordered byte stream.
    case concurrentRequest
    /// The client has already been closed.
    case closed
}
