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
