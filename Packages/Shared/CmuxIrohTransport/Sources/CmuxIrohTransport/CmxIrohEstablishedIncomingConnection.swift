/// Wraps an already-established connection as an incoming attempt.
///
/// Alternate transports and test endpoints that produce finished connections
/// use this to satisfy the accept contract; ``establish()`` returns
/// immediately.
public struct CmxIrohEstablishedIncomingConnection: CmxIrohIncomingConnection {
    private let connection: any CmxIrohConnection

    /// Wraps `connection` as an attempt whose handshake already completed.
    public init(_ connection: any CmxIrohConnection) {
        self.connection = connection
    }

    /// Returns the wrapped connection immediately; the handshake completed
    /// before this attempt was created.
    public func establish() async throws -> any CmxIrohConnection {
        connection
    }

    /// Closes the wrapped connection; with the handshake already complete,
    /// closing is the only way to release the attempt.
    public func abandon() async {
        await connection.close(errorCode: 1, reason: "admission_abandoned")
    }
}
