import CryptoKit
import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxIrohTransport

extension CmxIrohRegistryContextProviderTests {
    @Test
    func authenticatedRemovalRevokesLANAuthorityBeforeFallbackCanBrowse() async throws {
        let fixture = try RegistryFixture()
        let recorder = TestLANFallbackRecorder(hints: [])
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(targetHints: []),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            networkPathSnapshot: {
                CmxIrohNetworkPathSnapshot(generation: 1, activeNetworkProfiles: [])
            },
            lanFallback: { target, bindings, rendezvous in
                await recorder.provide(
                    target: target,
                    bindings: bindings,
                    rendezvous: rendezvous
                )
            },
            now: { fixture.now }
        )
        let request = try fixture.request(hints: [])
        let oldContext = try await provider.context(for: request)

        await broker.setDiscovery(try fixture.discovery(
            targetHints: [],
            includeTarget: false
        ))
        await #expect(throws: CmxIrohRegistryContextError.targetBindingUnavailable) {
            try await provider.context(for: request)
        }

        let fallback = try await provider.contextWithPrivateFallback(
            for: request,
            basedOn: oldContext
        )
        #expect(fallback == oldContext)
        #expect(await recorder.callCount() == 0)
    }

    @Test
    func policyEligibleFallbacksSurviveUnusableRegistryHintFlood() async throws {
        let fixture = try RegistryFixture()
        let profile = try CmxIrohNetworkProfileKey(
            source: .tailscale,
            profileID: opaqueProfileID("tailnet-a")
        )
        let managedRelay = try CmxIrohPathHint(
            kind: .relayURL,
            value: fixture.relayURL,
            source: .native,
            privacyScope: .publicInternet
        )
        let tailscale = try CmxIrohPathHint(
            kind: .directAddress,
            value: "100.64.0.8:4242",
            source: .tailscale,
            privacyScope: .privateNetwork,
            observedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(30 * 60),
            networkProfile: profile
        )
        let unusableRegistryHints = try (0 ..< CmxAttachEndpoint.maximumIrohPathHintCount).map {
            try CmxIrohPathHint(
                kind: .directAddress,
                value: "10.0.0.\($0 + 1):4242",
                source: .customVPN,
                privacyScope: .privateNetwork,
                observedAt: fixture.now,
                expiresAt: fixture.now.addingTimeInterval(30 * 60),
                networkProfile: CmxIrohNetworkProfileKey(
                    source: .customVPN,
                    profileID: opaqueProfileID("inactive-\($0)")
                )
            )
        }
        let discovery = try fixture.discovery(
            targetHints: unusableRegistryHints,
            targetDirectPorts: ["ipv4": 4_242]
        )
        let response = try fixture.pairGrantResponse(
            issuedAt: fixture.nowSeconds,
            expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
        )
        let broker = TestIrohRegistryBroker(
            discovery: discovery,
            pairGrantResponses: [response]
        )
        let supervisor = try await fixture.activeSupervisor()
        let pathSnapshot = CmxIrohNetworkPathSnapshot(
            generation: 41,
            activeNetworkProfiles: [profile]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: supervisor,
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            networkPathSnapshot: { pathSnapshot },
            now: { fixture.now }
        )
        let request = try fixture.request(hints: [managedRelay, tailscale])

        let context = try await provider.context(for: request)

        #expect(context.dialPlan.publicPaths == [managedRelay])
        #expect(context.dialPlan.privateFallbackPaths == [tailscale])
        #expect(context.credential.kind == .pairGrant)
        #expect(context.credential.pairGrantToken == response.grant)
        let authorization = try #require(context.privateFallbackAuthorization)
        #expect(authorization.networkPathSnapshot == pathSnapshot)
        #expect(authorization.pathHints == [tailscale])
        #expect(authorization.admittedAt == fixture.now)
        #expect(await broker.observedPairGrantRequests() == [
            .init(
                initiatorBindingID: fixture.initiator.bindingID,
                acceptorBindingID: fixture.acceptor.bindingID
            ),
        ])
    }

    @Test
    func privateFallbackRevalidationRejectsChangedOrUnavailableNetworkState() async throws {
        let fixture = try RegistryFixture()
        let profile = try CmxIrohNetworkProfileKey(
            source: .tailscale,
            profileID: opaqueProfileID("tailnet-a")
        )
        let privateHint = try CmxIrohPathHint(
            kind: .directAddress,
            value: "100.64.0.8:4242",
            source: .tailscale,
            privacyScope: .privateNetwork,
            observedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(30 * 60),
            networkProfile: profile
        )
        let response = try fixture.pairGrantResponse(
            issuedAt: fixture.nowSeconds,
            expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
        )
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(targetHints: [privateHint]),
            pairGrantResponses: [response]
        )
        let pathState = TestNetworkPathState(
            snapshot: CmxIrohNetworkPathSnapshot(
                generation: 9,
                activeNetworkProfiles: [profile]
            )
        )
        let clock = TestRegistryClock(fixture.now)
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            networkPathSnapshot: { try await pathState.currentSnapshot() },
            now: { clock.value() }
        )
        let context = try await provider.context(for: fixture.request(hints: []))
        let authorization = try #require(context.privateFallbackAuthorization)

        await pathState.setSnapshot(CmxIrohNetworkPathSnapshot(
            generation: 10,
            activeNetworkProfiles: [profile]
        ))
        await #expect(throws: CmxIrohPrivateFallbackValidationError.generationChanged) {
            try await provider.validatePrivateFallback(authorization)
        }

        await pathState.setSnapshot(CmxIrohNetworkPathSnapshot(
            generation: 9,
            activeNetworkProfiles: []
        ))
        await #expect(throws: CmxIrohPrivateFallbackValidationError.profileUnavailable) {
            try await provider.validatePrivateFallback(authorization)
        }

        await pathState.setSnapshot(CmxIrohNetworkPathSnapshot(
            generation: 9,
            activeNetworkProfiles: [profile]
        ))
        clock.set(fixture.now.addingTimeInterval(30 * 60 + 1))
        await #expect(throws: CmxIrohPrivateFallbackValidationError.hintExpiredOrInvalid) {
            try await provider.validatePrivateFallback(authorization)
        }

        clock.set(fixture.now)
        await pathState.setUnavailable()
        await #expect(throws: CmxIrohPrivateFallbackValidationError.unavailable) {
            try await provider.validatePrivateFallback(authorization)
        }
    }

    @Test
    func generationlessProfileSourceCannotAdmitPrivateFallback() async throws {
        let fixture = try RegistryFixture()
        let profile = try CmxIrohNetworkProfileKey(
            source: .tailscale,
            profileID: opaqueProfileID("tailnet-a")
        )
        let privateHint = try CmxIrohPathHint(
            kind: .directAddress,
            value: "100.64.0.8:4242",
            source: .tailscale,
            privacyScope: .privateNetwork,
            observedAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(30 * 60),
            networkProfile: profile
        )
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(targetHints: [privateHint]),
            pairGrantResponses: [try fixture.pairGrantResponse(
                issuedAt: fixture.nowSeconds,
                expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
            )]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [profile] },
            now: { fixture.now }
        )

        let context = try await provider.context(for: fixture.request(hints: []))

        #expect(context.dialPlan.privateFallbackPaths.isEmpty)
        #expect(context.privateFallbackAuthorization == nil)
    }

    @Test
    func signedExpiryDrivesCacheRefreshBoundary() async throws {
        let fixture = try RegistryFixture()
        let clock = TestRegistryClock(fixture.now)
        let refreshedAt = fixture.now.addingTimeInterval(4 * 24 * 60 * 60 + 1)
        let refreshedSeconds = Int64(refreshedAt.timeIntervalSince1970)
        let first = try fixture.pairGrantResponse(
            issuedAt: fixture.nowSeconds,
            expiresAt: fixture.nowSeconds + 7 * 24 * 60 * 60
        )
        let second = try fixture.pairGrantResponse(
            issuedAt: refreshedSeconds,
            expiresAt: refreshedSeconds + 7 * 24 * 60 * 60
        )
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(targetHints: []),
            pairGrantResponses: [first, second]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            now: { clock.value() }
        )
        let request = try fixture.request(hints: [])

        #expect(try await provider.context(for: request).credential.pairGrantToken == first.grant)
        #expect(try await provider.context(for: request).credential.pairGrantToken == first.grant)
        #expect(await broker.pairGrantRequestCount() == 1)

        clock.set(refreshedAt)
        #expect(try await provider.context(for: request).credential.pairGrantToken == second.grant)
        #expect(await broker.pairGrantRequestCount() == 2)
    }

    @Test
    func responseExpiryMustMatchSignedGrantExpiry() async throws {
        let fixture = try RegistryFixture()
        let signedExpiry = fixture.nowSeconds + 7 * 24 * 60 * 60
        let token = try fixture.pairGrant(
            issuedAt: fixture.nowSeconds,
            expiresAt: signedExpiry
        )
        let inconsistent = try fixture.pairGrantResponse(
            token: token,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(signedExpiry + 60))
        )
        let broker = TestIrohRegistryBroker(
            discovery: try fixture.discovery(targetHints: []),
            pairGrantResponses: [inconsistent]
        )
        let provider = CmxIrohRegistryContextProvider(
            supervisor: try await fixture.activeSupervisor(),
            broker: broker,
            localBindingExpectation: try fixture.localExpectation(),
            managedRelayURLs: [fixture.relayURL],
            activeNetworkProfiles: { [] },
            now: { fixture.now }
        )

        await #expect(throws: CmxIrohRegistryContextError.invalidGrantExpiry) {
            try await provider.context(for: fixture.request(hints: []))
        }
    }

}
