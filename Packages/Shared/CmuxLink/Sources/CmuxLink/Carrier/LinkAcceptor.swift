/// The host side of a carrier: every transport a dialer opened.
public protocol LinkAcceptor: Sendable {
    var incoming: AsyncStream<any LinkTransport> { get }
}
