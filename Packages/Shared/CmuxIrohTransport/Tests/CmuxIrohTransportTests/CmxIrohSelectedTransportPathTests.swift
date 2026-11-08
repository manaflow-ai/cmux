import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohSelectedTransportPathTests {
    @Test
    func selectedIPPathsAreReducedToPublicOrPrivateCategories() {
        let publicPath = CmxIrohObservedConnectionPath(snapshots: [
            snapshot(address: "203.0.113.40:443", isIP: true),
        ])
        let lanPath = CmxIrohObservedConnectionPath(snapshots: [
            snapshot(address: "192.168.1.20:443", isIP: true),
        ])
        let tailscalePath = CmxIrohObservedConnectionPath(snapshots: [
            snapshot(address: "100.100.20.40:443", isIP: true),
        ])
        let ipv6Path = CmxIrohObservedConnectionPath(snapshots: [
            snapshot(address: "[fd12:3456::9]:443", isIP: true),
        ])
        let scopedIPv6Path = CmxIrohObservedConnectionPath(snapshots: [
            snapshot(address: "[fe80::1%en0]:443", isIP: true),
        ])

        #expect(publicPath == .direct)
        #expect(lanPath == .privateNetwork)
        #expect(tailscalePath == .privateNetwork)
        #expect(ipv6Path == .privateNetwork)
        #expect(scopedIPv6Path == .privateNetwork)
    }

    @Test
    func managedRelayAttributionComesFromVerifiedPolicyLabels() throws {
        let url = "https://use1.relay.cmux.dev/"
        let descriptor = CmxIrohManagedRelayDescriptor(
            id: "cmux-use1",
            provider: "cmux",
            region: "us-east1",
            url: url
        )
        let policy = CmxIrohManagedRelayPolicy(
            version: 1,
            policyID: "123e4567-e89b-42d3-a456-426614174000",
            sequence: 7,
            issuedAt: 1_782_000_000,
            notBefore: 1_782_000_000,
            expiresAt: 1_782_003_600,
            audience: "cmux-iroh-relay-policy",
            relayProtocol: "iroh-relay-v1",
            relays: [descriptor]
        )
        let endpointProfile = try CmxIrohEndpointRelayProfile(
            managedRelayURLs: [url],
            relays: []
        )
        let effective = CmxIrohEffectiveRelayPolicy(
            endpointRelayProfile: endpointProfile,
            managedSnapshot: nil,
            managedPolicy: policy,
            requestedConfiguration: .automatic,
            effectivePreference: .automatic,
            source: .managed,
            usedCachedPolicy: false,
            preferenceRevision: 3
        )
        let classifier = CmxIrohSelectedTransportPathClassifier(policy: effective)

        #expect(classifier.classify(.relay(url: url)) == .managedRelay(
            provider: "cmux",
            region: "us-east1"
        ))
        #expect(classifier.classify(.relay(url: "https://substituted.example/")) == .unavailable)
    }

    @Test
    func customRelayAttributionUsesOnlyEffectiveAccountDefinition() throws {
        let url = "https://relay.example.net:8443/"
        let definition = try CmxIrohCustomRelayDefinition(
            id: "office",
            url: url,
            provider: "My Network",
            region: "Office",
            displayName: "Office Relay",
            authMode: .none
        )
        let endpointProfile = CmxIrohEndpointRelayProfile(
            customProfile: try CmxIrohCustomRelayProfile(
                relays: [try CmxIrohCustomRelay(url: url)]
            )
        )
        let effective = CmxIrohEffectiveRelayPolicy(
            endpointRelayProfile: endpointProfile,
            managedSnapshot: nil,
            managedPolicy: nil,
            requestedConfiguration: try .custom([definition]),
            effectivePreference: .custom([definition]),
            source: .custom,
            usedCachedPolicy: false,
            preferenceRevision: 5
        )
        let classifier = CmxIrohSelectedTransportPathClassifier(policy: effective)

        #expect(classifier.classify(.relay(url: url)) == .customRelay(
            displayName: "Office Relay",
            provider: "My Network",
            region: "Office"
        ))
    }

    private func snapshot(
        address: String,
        isIP: Bool = false,
        isRelay: Bool = false
    ) -> CmxIrohConnectionPathSnapshot {
        CmxIrohConnectionPathSnapshot(
            isSelected: true,
            remoteAddress: address,
            isIP: isIP,
            isRelay: isRelay
        )
    }
}
