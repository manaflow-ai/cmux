import Foundation

/// Wire constants for Direct QUIC: irx over Network.framework QUIC to an
/// exact host and port, with no relay and no path discovery.
public struct DirectQuicProtocol: Sendable {
    /// The constants are fixed; instances exist only to read them.
    public init() {}

    /// Distinct from Iroh's `cmux/irx/1` so the two carriers never
    /// half-connect to each other.
    public let alpn = "cmux/direct-quic/1"
    /// Stream budget each side grants the other. irx needs one control lane,
    /// one keepalive lane, and one lane per open terminal or artifact.
    let maximumStreams = 256
    /// A peer that vanishes without a close (crash, network loss) is declared
    /// dead after this long without packets.
    let idleTimeoutMilliseconds = 15_000
    /// QUIC PING cadence keeping a healthy idle connection under the timeout.
    let keepAliveSeconds = 5
    /// Largest single receive a stream read asks of Network.framework.
    let readChunkByteCount = 1 << 16

    /// The first byte of every carrier stream. Network.framework does not
    /// expose a stream's direction to the acceptor, so every carrier stream is
    /// bidirectional and this byte names its role.
    enum StreamKind: UInt8 {
        /// Two-way application lane.
        case bidirectional = 1
        /// One-way lane; the acceptor never writes back.
        case unidirectional = 2
        /// Carries the attributed close reason, then the connection ends.
        case close = 3
        /// The mutual device-key handshake.
        case handshake = 4
    }
}
