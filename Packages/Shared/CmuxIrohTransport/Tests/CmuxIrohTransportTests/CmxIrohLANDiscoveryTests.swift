import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohLANDiscoveryTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_001)

    @Test
    func builderPublishesOnlyRotatingAliasAndExactInterfaceAddresses() throws {
        let binding = try makeBinding()
        let advertisements = try CmxIrohLANAdvertisementBuilder().advertisements(
            rendezvous: makeRendezvous(),
            binding: binding,
            directAddresses: [
                "0.0.0.0:50906",
                "192.168.1.10:50907",
                "203.0.113.9:50908",
                "not-an-address",
            ],
            interfaces: [
                try interface(4, "192.168.1.10", "255.255.255.0"),
                try interface(5, "10.0.0.2", "255.255.255.0"),
            ],
            at: date
        )

        #expect(advertisements.map(\.interfaceIndex) == [4, 5])
        #expect(advertisements[0].addresses.map(\.value) == [
            "192.168.1.10:50906",
            "192.168.1.10:50907",
        ])
        #expect(advertisements[1].addresses.map(\.value) == ["10.0.0.2:50906"])
        for advertisement in advertisements {
            #expect(advertisement.alias.utf8.count == 32)
            #expect(advertisement.hostTarget == "h-\(advertisement.alias).local.")
            let payload = String(decoding: advertisement.txtRecord, as: UTF8.self)
            #expect(!payload.contains(binding.bindingID))
            #expect(!payload.contains(binding.endpointID.endpointID))
            #expect(!payload.contains(binding.deviceID))
            #expect(!payload.contains(binding.tag))
            #expect(!advertisement.hostTarget.contains("Mac"))
        }
    }

    @Test
    func builderRotatesServiceAndHostWithoutChangingReachability() throws {
        let builder = CmxIrohLANAdvertisementBuilder()
        let arguments = (
            rendezvous: makeRendezvous(),
            binding: try makeBinding(),
            directAddresses: ["192.168.1.10:50906"],
            interfaces: [try interface(4, "192.168.1.10", "255.255.255.0")]
        )
        let first = try #require(builder.advertisements(
            rendezvous: arguments.rendezvous,
            binding: arguments.binding,
            directAddresses: arguments.directAddresses,
            interfaces: arguments.interfaces,
            at: date
        ).first)
        let next = try #require(builder.advertisements(
            rendezvous: arguments.rendezvous,
            binding: arguments.binding,
            directAddresses: arguments.directAddresses,
            interfaces: arguments.interfaces,
            at: date.addingTimeInterval(300)
        ).first)

        #expect(first.alias != next.alias)
        #expect(first.hostTarget != next.hostTarget)
        #expect(first.addresses == next.addresses)
    }

    @Test
    func txtCodecRejectsNonCanonicalAndDuplicateAddresses() throws {
        let valid = try CmxIrohLANTXTRecord(
            epoch: 6_000_000,
            addresses: [try CmxIrohLANSocketAddress("192.168.1.10:50906")]
        )
        #expect(try CmxIrohLANTXTRecord(encoded: valid.encoded()) == valid)

        let duplicate = try CmxIrohLANSocketAddress("192.168.1.10:50906")
        #expect(throws: CmxIrohLANDiscoveryError.invalidTXTRecord) {
            _ = try CmxIrohLANTXTRecord(epoch: 1, addresses: [duplicate, duplicate])
        }
        #expect(throws: CmxIrohLANDiscoveryError.invalidSocketAddress) {
            _ = try CmxIrohLANSocketAddress("192.168.001.10:50906")
        }
        #expect(throws: CmxIrohLANDiscoveryError.invalidSocketAddress) {
            _ = try CmxIrohLANSocketAddress("127.0.0.1:50906")
        }
        #expect(throws: CmxIrohLANDiscoveryError.invalidSocketAddress) {
            _ = try CmxIrohLANSocketAddress("[fe80::1]:50906")
        }
    }

    @Test
    func resolverMapsOnlyOneAuthenticatedExpectedMacAndBuildsFallbackHints() throws {
        let rendezvous = makeRendezvous()
        let binding = try makeBinding()
        let advertisement = try #require(CmxIrohLANAdvertisementBuilder().advertisements(
            rendezvous: rendezvous,
            binding: binding,
            directAddresses: ["192.168.1.10:50906"],
            interfaces: [try interface(4, "192.168.1.10", "255.255.255.0")],
            at: date
        ).first)
        let path = CmxIrohNetworkPathSnapshot(generation: 7, activeNetworkProfiles: [])
        let resolved = try CmxIrohLANDiscoveryResolver().resolve(
            service(advertisement),
            rendezvous: rendezvous,
            authenticatedBindings: [binding],
            expectedMacDeviceID: binding.deviceID,
            expectedEndpointID: binding.endpointID,
            networkPathSnapshot: path,
            interfaces: [try interface(4, "192.168.1.22", "255.255.255.0")],
            at: date
        )

        #expect(resolved.binding == binding)
        #expect(resolved.pathGeneration == 7)
        #expect(resolved.pathHints.count == 1)
        #expect(resolved.pathHints[0].source == .lan)
        #expect(resolved.pathHints[0].privacyScope == .localNetwork)
        #expect(resolved.pathHints[0].use == .fallbackOnly)
        #expect(resolved.pathHints[0].networkProfile == resolved.networkProfile)
        let active = CmxIrohNetworkPathSnapshot(
            generation: path.generation,
            activeNetworkProfiles: [resolved.networkProfile]
        )
        #expect(throws: Never.self) {
            _ = try CmxIrohPrivateFallbackAuthorization(
                networkPathSnapshot: active,
                pathHints: resolved.pathHints,
                admittedAt: date
            )
        }
    }

    @Test
    func resolverRejectsUnknownAliasWrongSubnetAndDescriptiveHostname() throws {
        let rendezvous = makeRendezvous()
        let binding = try makeBinding()
        let advertisement = try #require(CmxIrohLANAdvertisementBuilder().advertisements(
            rendezvous: rendezvous,
            binding: binding,
            directAddresses: ["192.168.1.10:50906"],
            interfaces: [try interface(4, "192.168.1.10", "255.255.255.0")],
            at: date
        ).first)
        let resolver = CmxIrohLANDiscoveryResolver()
        let path = CmxIrohNetworkPathSnapshot(generation: 1, activeNetworkProfiles: [])

        #expect(throws: CmxIrohLANDiscoveryError.invalidInterface) {
            _ = try resolver.resolve(
                service(advertisement),
                rendezvous: rendezvous,
                authenticatedBindings: [binding],
                expectedMacDeviceID: binding.deviceID,
                networkPathSnapshot: path,
                interfaces: [try interface(4, "10.0.0.2", "255.255.255.0")],
                at: date
            )
        }
        let leaking = CmxIrohBonjourResolvedService(
            serviceName: advertisement.alias,
            hostTarget: "Lawrences-Mac.local.",
            interfaceIndex: advertisement.interfaceIndex,
            port: advertisement.port,
            txtRecord: advertisement.txtRecord
        )
        #expect(throws: CmxIrohLANDiscoveryError.invalidAdvertisement) {
            _ = try resolver.resolve(
                leaking,
                rendezvous: rendezvous,
                authenticatedBindings: [binding],
                expectedMacDeviceID: binding.deviceID,
                networkPathSnapshot: path,
                interfaces: [try interface(4, "192.168.1.22", "255.255.255.0")],
                at: date
            )
        }
        #expect(throws: CmxIrohLANDiscoveryError.ambiguousBinding) {
            _ = try resolver.resolve(
                service(advertisement),
                rendezvous: rendezvous,
                authenticatedBindings: [binding],
                expectedMacDeviceID: "123e4567-e89b-42d3-a456-426614174099",
                networkPathSnapshot: path,
                interfaces: [try interface(4, "192.168.1.22", "255.255.255.0")],
                at: date
            )
        }
    }

    @Test
    func resolverRejectsAddressOwnedByOverlappingInterfaces() throws {
        let rendezvous = makeRendezvous()
        let binding = try makeBinding()
        let advertisement = try #require(CmxIrohLANAdvertisementBuilder().advertisements(
            rendezvous: rendezvous,
            binding: binding,
            directAddresses: ["192.168.1.10:50906"],
            interfaces: [try interface(4, "192.168.1.10", "255.255.255.0")],
            at: date
        ).first)

        #expect(throws: CmxIrohLANDiscoveryError.invalidInterface) {
            _ = try CmxIrohLANDiscoveryResolver().resolve(
                service(advertisement),
                rendezvous: rendezvous,
                authenticatedBindings: [binding],
                expectedMacDeviceID: binding.deviceID,
                expectedEndpointID: binding.endpointID,
                networkPathSnapshot: .init(
                    generation: 1,
                    activeNetworkProfiles: []
                ),
                interfaces: [
                    try interface(4, "192.168.1.22", "255.255.255.0"),
                    try interface(5, "192.168.1.33", "255.255.255.0"),
                ],
                at: date
            )
        }
    }

    @Test
    func resolverRejectsReplayedEpochEvenWithKnownAlias() throws {
        let rendezvous = makeRendezvous()
        let binding = try makeBinding()
        let oldDate = date.addingTimeInterval(-900)
        let advertisement = try #require(CmxIrohLANAdvertisementBuilder().advertisements(
            rendezvous: rendezvous,
            binding: binding,
            directAddresses: ["192.168.1.10:50906"],
            interfaces: [try interface(4, "192.168.1.10", "255.255.255.0")],
            at: oldDate
        ).first)

        #expect(throws: (any Error).self) {
            _ = try CmxIrohLANDiscoveryResolver().resolve(
                service(advertisement),
                rendezvous: rendezvous,
                authenticatedBindings: [binding],
                expectedMacDeviceID: binding.deviceID,
                networkPathSnapshot: .init(generation: 1, activeNetworkProfiles: []),
                interfaces: [try interface(4, "192.168.1.22", "255.255.255.0")],
                at: date
            )
        }
    }

    @Test
    func profileChangesWithPathInterfaceAndBrokerGeneration() throws {
        let first = try CmxIrohLANNetworkProfileGenerator(rendezvous: makeRendezvous(generation: 1))
        let next = try CmxIrohLANNetworkProfileGenerator(rendezvous: makeRendezvous(generation: 2))
        let values = try Set([
            first.profile(interfaceIndex: 4, pathGeneration: 1),
            first.profile(interfaceIndex: 4, pathGeneration: 2),
            first.profile(interfaceIndex: 5, pathGeneration: 1),
            next.profile(interfaceIndex: 4, pathGeneration: 1),
        ])

        #expect(values.count == 4)
        #expect(values.allSatisfy { $0.source == .lan && $0.profileID.utf8.count == 64 })
    }

    @Test
    func interfaceFilterAllowsPhysicalAndConfiguredLANsButRejectsVirtualLinks() {
        for name in ["en0", "en12", "vlan0", "vlan42", "bond0"] {
            #expect(CmxIrohSystemLANInterfaceSnapshotProvider.isEligibleInterfaceName(name))
        }
        for name in [
            "lo0", "awdl0", "llw0", "ap1", "anpi0", "utun3", "ipsec0",
            "pdp_ip0", "bridge0", "gif0", "stf0", "vmenet0", "vmnet1",
            "tap0", "tun0", "docker0", "veth0", "en", "enx",
        ] {
            #expect(!CmxIrohSystemLANInterfaceSnapshotProvider.isEligibleInterfaceName(name))
        }
    }

    private func service(_ advertisement: CmxIrohLANAdvertisement) -> CmxIrohBonjourResolvedService {
        CmxIrohBonjourResolvedService(
            serviceName: advertisement.alias,
            hostTarget: advertisement.hostTarget,
            interfaceIndex: advertisement.interfaceIndex,
            port: advertisement.port,
            txtRecord: advertisement.txtRecord
        )
    }

    private func interface(
        _ index: UInt32,
        _ address: String,
        _ mask: String
    ) throws -> CmxIrohLANInterfaceAddress {
        try CmxIrohLANInterfaceAddress(
            interfaceIndex: index,
            ipAddress: address,
            netmask: mask
        )
    }

    private func makeRendezvous(generation: Int = 3) -> CmxIrohLANRendezvous {
        let key = Data(repeating: 7, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let data = try! JSONSerialization.data(withJSONObject: [
            "generation": generation,
            "key": key,
        ])
        return try! JSONDecoder().decode(CmxIrohLANRendezvous.self, from: data)
    }

    private func makeBinding() throws -> CmxIrohBrokerBindingMetadata {
        try CmxIrohBrokerBindingMetadata(
            bindingID: "123e4567-e89b-42d3-a456-426614174010",
            deviceID: "123e4567-e89b-42d3-a456-426614174011",
            appInstanceID: "123e4567-e89b-42d3-a456-426614174012",
            tag: "cmux-ios-v0",
            platform: .mac,
            endpointID: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
            identityGeneration: 4
        )
    }
}
