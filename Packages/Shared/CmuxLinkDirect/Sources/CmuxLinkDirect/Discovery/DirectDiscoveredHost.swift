/// A host advertising `_cmux._tcp` on the local link. The TXT record is
/// untrusted: it names the host so the app can look up the key it pinned at
/// pairing, and a spoofed record only fails the handshake.
public struct DirectDiscoveredHost: Sendable, Hashable {
    public var serviceName: String
    public var domain: String
    /// The advertised host id (TXT `host`), if any.
    public var hostID: String?

    public init(serviceName: String, domain: String, hostID: String?) {
        self.serviceName = serviceName
        self.domain = domain
        self.hostID = hostID
    }

    /// The endpoint to dial, pinned to the key from the trust store.
    public func endpoint(pinning hostKey: DirectPublicKey) -> DirectEndpoint {
        DirectEndpoint(target: .service(name: serviceName, type: DirectEndpoint.serviceType, domain: domain), hostKey: hostKey)
    }
}
