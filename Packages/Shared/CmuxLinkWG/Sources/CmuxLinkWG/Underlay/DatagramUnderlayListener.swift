/// The host side: every underlay a device opened (answered offers).
public protocol DatagramUnderlayListener: Sendable {
    var incoming: AsyncStream<any DatagramUnderlay> { get }
}
