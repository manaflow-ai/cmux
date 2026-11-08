/// The bounded startup wait expired before a connection became available.
public struct SocketStartupWaitTimeout: Error, Equatable, Sendable {
    /// The socket path selected by the final connection attempt.
    public let path: String

    /// Creates a timeout for the final attempted socket path.
    ///
    /// - Parameter path: The socket path selected by the final attempt.
    public init(path: String) {
        self.path = path
    }
}
