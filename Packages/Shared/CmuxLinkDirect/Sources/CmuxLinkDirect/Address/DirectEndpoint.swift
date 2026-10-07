/// One way to reach a host directly, with the key the host must prove.
public struct DirectEndpoint: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        /// A typed or synced address.
        case address(DirectAddress, port: UInt16)
        /// A Bonjour service found on the local link.
        case service(name: String, type: String, domain: String)
    }

    /// The port hosts listen on unless told otherwise.
    public static let defaultPort: UInt16 = 4180
    /// The Bonjour service type hosts advertise.
    public static let serviceType = "_cmux._tcp"

    public var target: Target
    /// The host's static key, pinned at pairing. Never taken from the network.
    public var hostKey: DirectPublicKey

    public init(target: Target, hostKey: DirectPublicKey) {
        self.target = target
        self.hostKey = hostKey
    }

    public init(address: DirectAddress, port: UInt16 = DirectEndpoint.defaultPort, hostKey: DirectPublicKey) {
        self.init(target: .address(address, port: port), hostKey: hostKey)
    }
}
