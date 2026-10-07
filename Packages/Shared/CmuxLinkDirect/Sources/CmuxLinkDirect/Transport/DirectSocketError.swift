/// A socket-level failure of a direct connection.
public enum DirectSocketError: Error, Sendable, Hashable {
    /// NWConnection has no route (it entered `.waiting`).
    case noRoute(String)
    case failed(String)
    /// The peer closed the byte stream.
    case endOfStream
    case cancelled
}
