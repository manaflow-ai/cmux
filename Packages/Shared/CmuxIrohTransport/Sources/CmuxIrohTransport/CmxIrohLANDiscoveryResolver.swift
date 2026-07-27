public import CMUXMobileCore
public import Foundation

/// A raw DNS-SD resolve result. Every field remains untrusted until resolved below.
public struct CmxIrohBonjourResolvedService: Equatable, Sendable {
    public let serviceName: String
    public let hostTarget: String
    public let interfaceIndex: UInt32
    public let port: UInt16
    public let txtRecord: Data

    public init(
        serviceName: String,
        hostTarget: String,
        interfaceIndex: UInt32,
        port: UInt16,
        txtRecord: Data
    ) {
        self.serviceName = serviceName
        self.hostTarget = hostTarget
        self.interfaceIndex = interfaceIndex
        self.port = port
        self.txtRecord = txtRecord
    }
}

/// An authenticated binding plus short-lived local reachability only.
public struct CmxIrohLANResolvedPeer: Equatable, Sendable {
    public let binding: CmxIrohBrokerBindingMetadata
    public let interfaceIndex: UInt32
    public let pathGeneration: UInt64
    public let networkProfile: CmxIrohNetworkProfileKey
    public let pathHints: [CmxIrohPathHint]
}

/// Maps an opaque service only to one already-authenticated same-account Mac.
public struct CmxIrohLANDiscoveryResolver: Sendable {
    public static let maximumHintTTL: TimeInterval = 60

    public init() {}

    public func resolve(
        _ service: CmxIrohBonjourResolvedService,
        rendezvous: CmxIrohLANRendezvous,
        authenticatedBindings: [CmxIrohBrokerBindingMetadata],
        expectedMacDeviceID: String,
        expectedEndpointID: CmxIrohPeerIdentity? = nil,
        networkPathSnapshot: CmxIrohNetworkPathSnapshot,
        interfaces: [CmxIrohLANInterfaceAddress],
        at date: Date
    ) throws -> CmxIrohLANResolvedPeer {
        guard CmxIrohLANRendezvousAliasGenerator.isCanonicalAlias(service.serviceName),
              service.hostTarget == "h-\(service.serviceName).local.",
              service.interfaceIndex != 0,
              service.port != 0,
              service.txtRecord.count <= CmxIrohLANTXTRecord.maximumEncodedSize else {
            throw CmxIrohLANDiscoveryError.invalidAdvertisement
        }
        let candidates = authenticatedBindings.filter { binding in
            binding.platform == .mac
                && cmxCanonicalDeviceID(binding.deviceID)
                    == cmxCanonicalDeviceID(expectedMacDeviceID)
                && (expectedEndpointID == nil || binding.endpointID == expectedEndpointID)
        }
        guard !candidates.isEmpty,
              candidates.count <= CmxIrohDiscoveryResponse.maximumBindingCount else {
            throw CmxIrohLANDiscoveryError.ambiguousBinding
        }
        let aliasGenerator = try CmxIrohLANRendezvousAliasGenerator(rendezvous: rendezvous)
        guard let binding = try aliasGenerator.binding(
            matching: service.serviceName,
            among: candidates,
            at: date
        ) else {
            throw CmxIrohLANDiscoveryError.ambiguousBinding
        }
        let txt = try CmxIrohLANTXTRecord(encoded: service.txtRecord)
        let currentEpoch = try CmxIrohLANRendezvousAliasGenerator.epoch(for: date)
        guard txt.epoch >= currentEpoch - 1,
              txt.epoch <= currentEpoch + 1,
              try aliasGenerator.alias(for: binding, epoch: txt.epoch) == service.serviceName,
              txt.addresses.first?.port == service.port else {
            throw CmxIrohLANDiscoveryError.staleAdvertisement
        }

        let matchingInterfaces = interfaces.filter {
            $0.interfaceIndex == service.interfaceIndex
        }
        guard !matchingInterfaces.isEmpty,
              txt.addresses.allSatisfy({ address in
                  let owningInterfaces = Set(
                      interfaces.lazy
                          .filter { $0.contains(address) }
                          .map(\.interfaceIndex)
                  )
                  return owningInterfaces == [service.interfaceIndex]
              }) else {
            throw CmxIrohLANDiscoveryError.invalidInterface
        }
        let profile = try CmxIrohLANNetworkProfileGenerator(rendezvous: rendezvous).profile(
            interfaceIndex: service.interfaceIndex,
            pathGeneration: networkPathSnapshot.generation
        )
        let epochLimit = Date(
            timeIntervalSince1970: (TimeInterval(txt.epoch) + 2)
                * CmxIrohLANRendezvousAliasGenerator.rotationInterval
        )
        let expiresAt = min(
            date.addingTimeInterval(Self.maximumHintTTL),
            epochLimit
        )
        guard expiresAt > date else { throw CmxIrohLANDiscoveryError.staleAdvertisement }
        let hints = try txt.addresses.map { address in
            try CmxIrohPathHint(
                kind: .directAddress,
                value: address.value,
                source: .lan,
                privacyScope: .localNetwork,
                observedAt: date,
                expiresAt: expiresAt,
                networkProfile: profile
            )
        }
        return CmxIrohLANResolvedPeer(
            binding: binding,
            interfaceIndex: service.interfaceIndex,
            pathGeneration: networkPathSnapshot.generation,
            networkProfile: profile,
            pathHints: hints
        )
    }
}
