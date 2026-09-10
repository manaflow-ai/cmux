/// One user-pinned address a per-Computer "Direct" Iroh dial may attempt.
///
/// Direct is the explicit fail-closed connection method: the enabled entries
/// configured on a Computer are the COMPLETE path allowlist for its dials.
/// The transport must not add relay paths, broker-advertised or discovered
/// direct paths, LAN-discovery joins, or custom private-path joins to a dial
/// carrying candidates, and it must fail the dial instead of substituting
/// another path when none of the candidates is usable.
public struct CmxIrohDirectDialCandidate: Equatable, Sendable {
    /// Numeric IPv4 or IPv6 literal without brackets, a port, or a zone.
    public let address: String

    /// Explicit UDP port override. `nil` joins the Mac's broker-published
    /// Iroh UDP port for the address family at dial time.
    public let port: UInt16?

    /// Creates one Direct dial candidate.
    public init(address: String, port: UInt16? = nil) {
        self.address = address
        self.port = port
    }
}
