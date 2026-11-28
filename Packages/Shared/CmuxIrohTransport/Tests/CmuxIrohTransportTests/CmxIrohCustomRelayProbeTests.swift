import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohCustomRelayProbeTests {
    @Test
    func isolatedProbeReportsOnlyAnAllowedAdvertisedRelayAndCloses() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let relayURL = "https://private.example.net:8443/"
        let now = Date()
        let hint = try CmxIrohPathHint(
            kind: .relayURL,
            value: relayURL,
            source: .native,
            privacyScope: .publicInternet,
            observedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID, pathHints: [hint])
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let profile = CmxIrohEndpointRelayProfile(
            customProfile: try CmxIrohCustomRelayProfile(
                relays: [CmxIrohCustomRelay(url: relayURL)]
            )
        )

        let result = await CmxIrohCustomRelayProbe(factory: factory).probe(
            profile: profile,
            timeout: 1
        )

        #expect(result == .reachable(relayURL: relayURL))
        #expect(await endpoint.observedCloseCallCount() == 1)
        let configuration = try #require(await factory.observedConfigurations().first)
        #expect(configuration.relayProfile == profile)
        #expect(configuration.secretKey != fixture.identity.secretKey)
    }

    @Test
    func managedProfileIsRejectedBeforeBinding() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let factory = TestIrohEndpointFactory(
            endpoints: [TestIrohEndpoint(identity: fixture.endpointID)]
        )
        let profile = try CmxIrohEndpointRelayProfile(
            managedRelayURLs: fixture.configuration.managedRelayURLs,
            relays: []
        )

        let result = await CmxIrohCustomRelayProbe(factory: factory).probe(
            profile: profile
        )

        #expect(result == .invalidProfile)
        #expect(await factory.observedConfigurations().isEmpty)
    }

    @Test
    func timeoutCancelsObservationAndClosesEndpoint() async throws {
        let fixture = try ClientRuntimeTestFixture()
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let profile = CmxIrohEndpointRelayProfile(
            customProfile: try CmxIrohCustomRelayProfile(
                relays: [CmxIrohCustomRelay(url: "https://private.example.net:8443/")]
            )
        )

        let result = await CmxIrohCustomRelayProbe(
            factory: factory,
            clock: ImmediateProbeClock()
        ).probe(profile: profile, timeout: 1)

        #expect(result == .timedOut)
        #expect(await endpoint.observedCloseCallCount() == 1)
    }
}

private struct ImmediateProbeClock: CmxIrohRelayClock {
    func now() -> Date {
        Date(timeIntervalSince1970: 1_000)
    }

    func sleep(until _: Date) async throws {}
}
