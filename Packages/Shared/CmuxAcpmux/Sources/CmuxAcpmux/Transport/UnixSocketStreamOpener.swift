public import CmuxConversation

/// Opens Unix-socket streams to acpmux on this Mac, for control and transfers.
public struct UnixSocketStreamOpener: ConversationStreamOpening {
    private let socketPath: @Sendable () async -> String?

    /// Creates an opener.
    /// - Parameter socketPath: Returns the daemon's socket path, or `nil`
    ///   while it is not running (asked on every open, so a restarted daemon
    ///   is found).
    public init(socketPath: @escaping @Sendable () async -> String?) {
        self.socketPath = socketPath
    }

    /// Opens a stream to the daemon.
    /// - Parameter purpose: Control or transfer; both use the same socket.
    /// - Returns: The stream.
    /// - Throws: When the daemon is not running or refuses.
    public func open(_ purpose: ConversationStreamPurpose) async throws -> any ConversationByteStream {
        guard let path = await socketPath() else {
            throw ConversationBackendError.unreachable("acpmux is not running")
        }
        return try await UnixSocketByteStream.connect(path: path)
    }
}
