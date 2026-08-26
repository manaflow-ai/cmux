public import Foundation

/// One incoming connection attempt whose server-side handshake has not
/// completed yet.
///
/// ``CmxIrohEndpoint/accept()`` returns this stage instead of a finished
/// connection so the accept loop's only job is draining the endpoint's accept
/// queue. The handshake is per-connection work owned by that connection's
/// admission task: a peer that stops making handshake progress (killed app,
/// dead relay path) can therefore never gate other peers' admissions.
public protocol CmxIrohIncomingConnection: Sendable {
    /// Completes the server-side handshake and returns the connection.
    ///
    /// - Returns: The TLS-authenticated connection.
    /// - Throws: A transport error when the handshake fails or the peer
    ///   negotiated an unexpected ALPN.
    func establish() async throws -> any CmxIrohConnection

    /// Abandons the attempt without completing the handshake.
    ///
    /// Safe to call after ``establish()`` started; the attempt's resources are
    /// released and an unfinished handshake is aborted by the driver.
    func abandon() async
}

/// Wraps an already-established connection as an incoming attempt.
///
/// Alternate transports and test endpoints that produce finished connections
/// use this to satisfy the accept contract; ``establish()`` returns
/// immediately.
public struct CmxIrohEstablishedIncomingConnection: CmxIrohIncomingConnection {
    private let connection: any CmxIrohConnection

    public init(_ connection: any CmxIrohConnection) {
        self.connection = connection
    }

    public func establish() async throws -> any CmxIrohConnection {
        connection
    }

    public func abandon() async {
        await connection.close(errorCode: 1, reason: "admission_abandoned")
    }
}
