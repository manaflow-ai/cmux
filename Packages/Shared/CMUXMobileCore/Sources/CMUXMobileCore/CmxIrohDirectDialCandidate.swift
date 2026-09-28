/// One user-pinned address a per-Computer "Direct" Iroh dial may attempt.
///
/// Direct is the explicit fail-closed connection method: the enabled entries
/// configured on a Computer are the COMPLETE path allowlist for its dials.
/// The transport must not add relay paths, broker-advertised or discovered
/// direct paths, LAN-discovery joins, or custom private-path joins to a dial
/// carrying candidates, and it must fail the dial instead of substituting
/// another path when none of the candidates is usable.
public struct CmxIrohDirectDialCandidate: Equatable, Sendable {
    /// The wire protocol a pinned candidate targets. Address entries saved
    /// before Direct QUIC shipped point at the Mac's Iroh listener port and
    /// carry no marker, so they stay on the pinned Iroh dial; entries the new
    /// flows create are marked for Direct QUIC. Rolling upgrades therefore
    /// strand neither side.
    public enum Transport: Equatable, Sendable {
        /// Pinned Iroh dial to exactly this address (pre-Direct QUIC entries).
        case iroh
        /// Network.framework QUIC with the device-key handshake.
        case directQuic
    }

    /// Numeric IPv4 or IPv6 literal without brackets, a port, or a zone.
    public let address: String

    /// Explicit local UDP port. The v2 transport rejects candidates without one.
    public let port: UInt16?

    /// The wire protocol this candidate was saved for.
    public let transport: Transport

    /// Creates one Direct dial candidate.
    public init(address: String, port: UInt16? = nil, transport: Transport = .iroh) {
        self.address = address
        self.port = port
        self.transport = transport
    }
}
