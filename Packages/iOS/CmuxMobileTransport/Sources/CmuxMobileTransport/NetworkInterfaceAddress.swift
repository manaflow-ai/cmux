import Foundation

/// One numeric self-address of one network interface, as enumerated from the
/// system. A plain value type so classification logic is testable with
/// injected fixtures.
public struct NetworkInterfaceAddress: Sendable, Equatable {
    /// The BSD interface name (for example `en0`, `utun4`, `pdp_ip0`).
    public let interfaceName: String
    /// The numeric address string (IPv4 dotted quad or IPv6, possibly with a
    /// `%zone` suffix as returned by `getnameinfo`).
    public let address: String

    /// Creates an interface-address pair.
    ///
    /// - Parameters:
    ///   - interfaceName: The BSD interface name.
    ///   - address: The numeric address string.
    public init(interfaceName: String, address: String) {
        self.interfaceName = interfaceName
        self.address = address
    }
}
