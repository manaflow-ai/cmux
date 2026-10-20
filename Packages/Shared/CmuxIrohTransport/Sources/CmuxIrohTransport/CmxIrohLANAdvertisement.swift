public import Foundation

/// One interface-scoped, privacy-preserving DNS-SD registration.
public struct CmxIrohLANAdvertisement: Equatable, Sendable {
    public static let serviceType = "_cmux-iroh._udp"
    public static let domain = "local."

    /// The rotating account-private service instance name.
    public let alias: String
    /// Explicit opaque SRV target. The system's descriptive hostname is never used.
    public let hostTarget: String
    public let interfaceIndex: UInt32
    public let port: UInt16
    public let addresses: [CmxIrohLANSocketAddress]
    public let txtRecord: Data
    public let expiresAt: Date

    init(
        alias: String,
        hostTarget: String,
        interfaceIndex: UInt32,
        port: UInt16,
        addresses: [CmxIrohLANSocketAddress],
        txtRecord: Data,
        expiresAt: Date
    ) throws {
        guard CmxIrohLANRendezvousAliasGenerator.isCanonicalAlias(alias),
              hostTarget == "h-\(alias).local.",
              hostTarget.utf8.count <= 253,
              interfaceIndex != 0,
              port != 0,
              !addresses.isEmpty,
              addresses.count <= CmxIrohLANTXTRecord.maximumAddressCount,
              addresses.contains(where: { $0.port == port }),
              txtRecord.count <= CmxIrohLANTXTRecord.maximumEncodedSize,
              expiresAt.timeIntervalSince1970.isFinite else {
            throw CmxIrohLANDiscoveryError.invalidAdvertisement
        }
        self.alias = alias
        self.hostTarget = hostTarget
        self.interfaceIndex = interfaceIndex
        self.port = port
        self.addresses = addresses
        self.txtRecord = txtRecord
        self.expiresAt = expiresAt
    }
}

/// Builds only interface-local advertisements from the endpoint's raw address view.
public struct CmxIrohLANAdvertisementBuilder: Sendable {
    public static let maximumRawAddressCount = 32
    public static let maximumInterfaceCount = 8

    public init() {}

    public func advertisements(
        rendezvous: CmxIrohLANRendezvous,
        binding: CmxIrohBrokerBindingMetadata,
        directAddresses: [String],
        interfaces: [CmxIrohLANInterfaceAddress],
        at date: Date
    ) throws -> [CmxIrohLANAdvertisement] {
        guard directAddresses.count <= Self.maximumRawAddressCount,
              interfaces.count <= 64 else {
            throw CmxIrohLANDiscoveryError.invalidAdvertisement
        }
        let generator = try CmxIrohLANRendezvousAliasGenerator(rendezvous: rendezvous)
        let alias = try generator.alias(for: binding, at: date)
        let epoch = try CmxIrohLANRendezvousAliasGenerator.epoch(for: date)
        let expiryValue = (TimeInterval(epoch) + 1) * CmxIrohLANRendezvousAliasGenerator.rotationInterval
        guard expiryValue.isFinite else { throw CmxIrohLANDiscoveryError.invalidAdvertisement }
        let expiresAt = Date(timeIntervalSince1970: expiryValue)

        let eligible = Array(Set(interfaces))
        var byInterface: [UInt32: Set<CmxIrohLANSocketAddress>] = [:]
        for raw in directAddresses {
            if let wildcard = CmxIrohLANSocketAddress.wildcard(raw) {
                for interface in eligible where interface.family == wildcard.family {
                    let value = CmxIrohLANSocketAddress.canonicalValue(
                        ipAddress: interface.ipAddress,
                        port: wildcard.port
                    )
                    if let socket = try? CmxIrohLANSocketAddress(value) {
                        byInterface[interface.interfaceIndex, default: []].insert(socket)
                    }
                }
                continue
            }
            guard let socket = try? CmxIrohLANSocketAddress(raw) else { continue }
            for interface in eligible where interface.ipAddress == socket.ipAddress {
                byInterface[interface.interfaceIndex, default: []].insert(socket)
            }
        }
        guard byInterface.count <= Self.maximumInterfaceCount else {
            throw CmxIrohLANDiscoveryError.invalidAdvertisement
        }

        return try byInterface.sorted(by: { $0.key < $1.key }).map { interfaceIndex, values in
            let addresses = values.sorted { $0.value < $1.value }
            let txt = try CmxIrohLANTXTRecord(epoch: epoch, addresses: addresses).encoded()
            return try CmxIrohLANAdvertisement(
                alias: alias,
                hostTarget: "h-\(alias).local.",
                interfaceIndex: interfaceIndex,
                port: addresses[0].port,
                addresses: addresses,
                txtRecord: txt,
                expiresAt: expiresAt
            )
        }
    }
}
