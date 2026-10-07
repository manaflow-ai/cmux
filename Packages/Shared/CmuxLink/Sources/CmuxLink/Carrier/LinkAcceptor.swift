/// The host side of a carrier: every transport a dialer opened.
public protocol LinkAcceptor: Sendable {
    var incoming: AsyncStream<any LinkTransport> { get }
}

extension LinkAcceptor {
    /// Authenticated transports an acceptor queues for a consumer that has not
    /// taken them yet. One past this is closed (the dialer retries), so a
    /// stalled host never queues connections without bound.
    public static var pendingTransportLimit: Int { 64 }
}
