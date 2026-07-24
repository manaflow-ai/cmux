import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct CmxPrivateNetworkAddressTests {
    @Test(
        arguments: [
            ("utun4", "10.8.0.1", CmxPrivateNetworkAddress.Kind.vpnTunnel),
            ("en0", "192.168.1.4", .localNetwork),
            ("utun9", "52.1.2.3", .vpnTunnel),
            ("mystery0", "fd00::1", .other),
        ]
    )
    func classifiesEligibleAddresses(
        interfaceName: String,
        address: String,
        kind: CmxPrivateNetworkAddress.Kind
    ) throws {
        let candidate = try #require(CmxPrivateNetworkAddress.classify(
            interfaceName: interfaceName,
            address: address
        ))
        #expect(candidate.address == address)
        #expect(candidate.kind == kind)
    }

    @Test(
        arguments: [
            ("utun4", "100.101.1.2"),
            ("en0", "169.254.5.5"),
            ("en0", "fe80::1"),
            ("en0", "127.0.0.1"),
            ("utun4", "0.0.0.0"),
            ("utun4", "::"),
            ("utun4", "224.0.0.1"),
            ("utun4", "ff02::1"),
            ("en0", "17.2.3.4"),
            ("utun4", "fd7a:115c:a1e0::1"),
            ("utun4", "10.8.0.1%utun4"),
            ("utun4", "[fd00::1]"),
            ("utun4", "vpn.internal.example"),
            ("awdl0", "192.168.1.4"),
        ]
    )
    func rejectsUnsafeOrIneligibleAddresses(
        interfaceName: String,
        address: String
    ) {
        #expect(CmxPrivateNetworkAddress.classify(
            interfaceName: interfaceName,
            address: address
        ) == nil)
    }

    @Test func validatesAndCanonicalizesConstruction() throws {
        let value = try #require(CmxPrivateNetworkAddress(
            address: "fd00:0:0:0:0:0:0:8",
            family: .ipv6,
            interfaceName: "utun4",
            kind: .vpnTunnel
        ))
        #expect(value.address == "fd00::8")
        #expect(value.id == "utun4/fd00::8")

        #expect(CmxPrivateNetworkAddress(
            address: "10.0.0.8",
            family: .ipv6,
            interfaceName: "utun4",
            kind: .vpnTunnel
        ) == nil)
        #expect(CmxPrivateNetworkAddress(
            address: "10.0.0.8",
            family: .ipv4,
            interfaceName: String(repeating: "a", count: 33),
            kind: .vpnTunnel
        ) == nil)
    }

    @Test func codableRoundTripsAndToleratesUnknownKeys() throws {
        let source = try #require(CmxPrivateNetworkAddress.classify(
            interfaceName: "en0",
            address: "192.168.1.4"
        ))
        let encoded = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(CmxPrivateNetworkAddress.self, from: encoded) == source)

        let withUnknownKey = Data(
            #"{"address":"192.168.1.4","family":"ipv4","interface":"en0","kind":"local_network","future":true}"#.utf8
        )
        #expect(
            try JSONDecoder().decode(
                CmxPrivateNetworkAddress.self,
                from: withUnknownKey
            ) == source
        )
    }

    @Test func sortingPrioritizesKindFamilyAndDeduplicates() throws {
        let vpnIPv6 = try #require(CmxPrivateNetworkAddress(
            address: "fd00::2",
            interfaceName: "utun2",
            kind: .vpnTunnel
        ))
        let vpnIPv4 = try #require(CmxPrivateNetworkAddress(
            address: "10.0.0.2",
            interfaceName: "utun2",
            kind: .vpnTunnel
        ))
        let local = try #require(CmxPrivateNetworkAddress(
            address: "192.168.1.4",
            interfaceName: "en0",
            kind: .localNetwork
        ))
        let other = try #require(CmxPrivateNetworkAddress(
            address: "172.16.0.2",
            interfaceName: "vbox0",
            kind: .other
        ))

        #expect(CmxPrivateNetworkAddress.sorted([
            other, local, vpnIPv6, vpnIPv4, local,
        ]) == [
            vpnIPv4, vpnIPv6, local, other,
        ])
    }
}
