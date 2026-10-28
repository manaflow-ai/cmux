/// Opens the long-lived line connections of the acpmux watches (the turn states, the Chats index). The app's opens a
/// Unix socket connection; a test's records each open, so it can show that no watch connects before the launch's first
/// frame (p08-startup-097).
///
/// ```swift
/// let connection = connector.connection(to: socketPath)
/// connection.start(send: request, decode: Message.init(line:)) { drain in ... }
/// ```
public nonisolated struct AgentActivityConnector: Sendable {
    private let open: @Sendable (_ path: String) -> AgentActivityLineConnection

    /// - Parameter open: Makes the connection to the socket at `path` (not started).
    public init(_ open: @escaping @Sendable (_ path: String) -> AgentActivityLineConnection) {
        self.open = open
    }

    /// The app's: a plain connection to the socket.
    public static let unixSocket = AgentActivityConnector { AgentActivityLineConnection(path: $0) }

    /// A new connection to the socket at `path`, not started.
    public func connection(to path: String) -> AgentActivityLineConnection {
        open(path)
    }
}
