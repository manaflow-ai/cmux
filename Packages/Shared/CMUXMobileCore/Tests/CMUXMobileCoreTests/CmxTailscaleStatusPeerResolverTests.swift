import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct CmxTailscaleStatusPeerResolverTests {
    private let resolver = CmxTailscaleStatusPeerResolver()

    @Test func resolvesOneExactDualStackPeerAndPrefersIPv4() throws {
        let record = try resolver.resolve(
            magicDNSName: " WORK-MAC.TAILNET.TS.NET. ",
            statusJSON: statusJSON(peers: [
                peer(
                    id: "node-1",
                    dnsName: "work-mac.tailnet.ts.net.",
                    addresses: ["fd7a:115c:a1e0::1234", "100.71.210.41"]
                ),
            ])
        )

        #expect(record.stableID == "node-1")
        #expect(record.dnsName == "work-mac.tailnet.ts.net")
        #expect(record.addresses.map(\.value) == ["100.71.210.41", "fd7a:115c:a1e0::1234"])
        #expect(record.preferredAddress.value == "100.71.210.41")
        #expect(!record.isLocalDevice)
    }

    @Test func resolvesIPv6OnlyPeerWithoutFallingBackToGenericPrivateNetworking() throws {
        let record = try resolver.resolve(
            magicDNSName: "work-mac.tailnet.ts.net",
            statusJSON: statusJSON(peers: [
                peer(
                    id: "node-1",
                    dnsName: "work-mac.tailnet.ts.net.",
                    addresses: ["fd7a:115c:a1e0:0:0:0:0:1234"]
                ),
            ])
        )

        #expect(record.preferredAddress.value == "fd7a:115c:a1e0::1234")
        #expect(record.preferredAddress.family == .ipv6)
    }

    @Test func rejectsNoMatchAndSuffixSubstitution() throws {
        let status = try statusJSON(peers: [
            peer(
                id: "node-1",
                dnsName: "work-mac.tailnet.ts.net.",
                addresses: ["100.71.210.41"]
            ),
        ])

        #expect(throws: CmxTailscaleStatusPeerResolutionError.peerNotFound) {
            _ = try resolver.resolve(
                magicDNSName: "other-mac.tailnet.ts.net",
                statusJSON: status
            )
        }
        #expect(throws: CmxTailscaleStatusPeerResolutionError.invalidMagicDNSName) {
            _ = try resolver.resolve(
                magicDNSName: "work-mac.tailnet.ts.net.attacker.example",
                statusJSON: status
            )
        }
    }

    @Test func rejectsTwoPeerRecordsClaimingTheSameName() throws {
        let status = try statusJSON(peers: [
            peer(
                id: "node-1",
                dnsName: "work-mac.tailnet.ts.net.",
                addresses: ["100.71.210.41"]
            ),
            peer(
                id: "node-2",
                dnsName: "work-mac.tailnet.ts.net.",
                addresses: ["100.72.1.9"]
            ),
        ])

        #expect(throws: CmxTailscaleStatusPeerResolutionError.ambiguousPeer) {
            _ = try resolver.resolve(
                magicDNSName: "work-mac.tailnet.ts.net",
                statusJSON: status
            )
        }
    }

    @Test(arguments: [
        ["100.71.210.41", "203.0.113.10"],
        ["100.71.210.41", "192.168.1.20"],
        ["100.71.210.41", "fd7a:115c:a1e0::53"],
        ["100.100.100.100"],
        ["not-an-address"],
    ])
    func rejectsMixedPublicPrivateServiceAndMalformedPeerAddresses(
        _ addresses: [String]
    ) throws {
        let status = try statusJSON(peers: [
            peer(
                id: "node-1",
                dnsName: "work-mac.tailnet.ts.net.",
                addresses: addresses
            ),
        ])

        #expect(throws: CmxTailscaleStatusPeerResolutionError.invalidPeerAddress) {
            _ = try resolver.resolve(
                magicDNSName: "work-mac.tailnet.ts.net",
                statusJSON: status
            )
        }
    }

    @Test func rejectsTheLocalDeviceForManualPeerAddButCanResolveSelfPublication() throws {
        let status = try statusJSON(
            local: peer(
                id: "self-node",
                dnsName: "this-mac.tailnet.ts.net.",
                addresses: ["100.70.1.5", "fd7a:115c:a1e0::5"]
            ),
            peers: []
        )

        #expect(throws: CmxTailscaleStatusPeerResolutionError.localDeviceNotAllowed) {
            _ = try resolver.resolve(
                magicDNSName: "this-mac.tailnet.ts.net",
                statusJSON: status
            )
        }
        let local = try resolver.resolve(
            magicDNSName: "this-mac.tailnet.ts.net",
            statusJSON: status,
            allowLocalDevice: true
        )
        #expect(local.isLocalDevice)
        #expect(local.preferredAddress.value == "100.70.1.5")
    }

    @Test func rejectsEmptyAddressesMalformedStatusAndOversizedStatus() throws {
        let emptyAddresses = try statusJSON(peers: [
            peer(
                id: "node-1",
                dnsName: "work-mac.tailnet.ts.net.",
                addresses: []
            ),
        ])
        #expect(throws: CmxTailscaleStatusPeerResolutionError.missingPeerAddresses) {
            _ = try resolver.resolve(
                magicDNSName: "work-mac.tailnet.ts.net",
                statusJSON: emptyAddresses
            )
        }
        #expect(throws: CmxTailscaleStatusPeerResolutionError.malformedStatus) {
            _ = try resolver.resolve(
                magicDNSName: "work-mac.tailnet.ts.net",
                statusJSON: Data("[]".utf8)
            )
        }
        #expect(throws: CmxTailscaleStatusPeerResolutionError.malformedStatus) {
            _ = try resolver.resolve(
                magicDNSName: "work-mac.tailnet.ts.net",
                statusJSON: Data(repeating: 0x20, count: CmxTailscaleStatusPeerResolver.maximumStatusBytes + 1)
            )
        }
    }

    @Test func rejectsCachedPeerMapWhenTailscaleIsNotRunning() throws {
        let status = try statusJSON(
            backendState: "Stopped",
            peers: [
                peer(
                    id: "node-1",
                    dnsName: "work-mac.tailnet.ts.net.",
                    addresses: ["100.71.210.41"]
                ),
            ]
        )

        #expect(throws: CmxTailscaleStatusPeerResolutionError.statusNotRunning) {
            _ = try resolver.resolve(
                magicDNSName: "work-mac.tailnet.ts.net",
                statusJSON: status
            )
        }
    }

    private func statusJSON(
        backendState: String = "Running",
        local: [String: Any]? = nil,
        peers: [[String: Any]]
    ) throws -> Data {
        var root: [String: Any] = [
            "BackendState": backendState,
            "Peer": Dictionary(
                uniqueKeysWithValues: peers.enumerated().map { ("peer-\($0.offset)", $0.element) }
            ),
        ]
        if let local {
            root["Self"] = local
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func peer(
        id: String,
        dnsName: String,
        addresses: [String]
    ) -> [String: Any] {
        [
            "ID": id,
            "DNSName": dnsName,
            "TailscaleIPs": addresses,
        ]
    }
}
