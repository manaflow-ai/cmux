import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohEndpointSupervisorTests {
    private let identity: CmxIrohPeerIdentity

    init() throws {
        identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "ab", count: 32)
        )
    }

    @Test
    func repeatedActivationReusesOneBoundGeneration() async throws {
        let endpoint = TestIrohEndpoint(identity: identity)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let supervisor = try CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: endpointConfiguration()
        )

        let first = try await supervisor.activate()
        let second = try await supervisor.activate()

        #expect(first == second)
        #expect(first.state == .active)
        #expect(first.runtimeGeneration == 1)
        #expect(first.identity == identity)
        #expect(await factory.observedConfigurations().count == 1)
    }

    @Test
    func deactivationInvalidatesAndClosesAnInFlightBindResult() async throws {
        let endpoint = TestIrohEndpoint(identity: identity)
        let factory = TestBlockingIrohEndpointFactory(endpoint: endpoint)
        let supervisor = try CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: endpointConfiguration()
        )
        var started = await factory.bindStartedEvents().makeAsyncIterator()
        let activation = Task { try await supervisor.activate() }
        _ = await started.next()

        await supervisor.deactivate()
        await factory.release()

        await #expect(throws: CancellationError.self) {
            try await activation.value
        }
        #expect(await endpoint.observedCloseCallCount() == 1)
        await #expect(throws: CmxIrohEndpointSupervisorError.inactive) {
            try await supervisor.activeEndpoint()
        }
    }

    @Test
    func concurrentActivationSharesOneBindOperation() async throws {
        let endpoint = TestIrohEndpoint(identity: identity)
        let factory = TestBlockingIrohEndpointFactory(endpoint: endpoint)
        let supervisor = try CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: endpointConfiguration()
        )
        var started = await factory.bindStartedEvents().makeAsyncIterator()
        let first = Task { try await supervisor.activate() }
        let second = Task { try await supervisor.activate() }
        _ = await started.next()

        await factory.release()

        let firstSnapshot = try await first.value
        let secondSnapshot = try await second.value
        #expect(firstSnapshot == secondSnapshot)
        #expect(firstSnapshot.runtimeGeneration == 1)
        #expect(await endpoint.observedCloseCallCount() == 0)
    }

    @Test
    func unexpectedDriverCloseRebindsWithSameSecretAndNewRuntimeGeneration() async throws {
        let firstEndpoint = TestIrohEndpoint(identity: identity)
        let secondEndpoint = TestIrohEndpoint(identity: identity)
        let factory = TestIrohEndpointFactory(endpoints: [firstEndpoint, secondEndpoint])
        let configuration = try endpointConfiguration()
        let supervisor = CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: configuration
        )
        var events = await supervisor.events().makeAsyncIterator()
        #expect(await events.next() == .snapshot(CmxIrohEndpointSnapshot(
            runtimeGeneration: 0,
            state: .inactive,
            identity: nil
        )))

        _ = try await supervisor.activate()
        #expect(await events.next() == .snapshot(CmxIrohEndpointSnapshot(
            runtimeGeneration: 1,
            state: .starting,
            identity: nil
        )))
        #expect(await events.next() == .snapshot(CmxIrohEndpointSnapshot(
            runtimeGeneration: 1,
            state: .active,
            identity: identity
        )))
        await firstEndpoint.emit(.closedUnexpectedly)
        #expect(await events.next() == .snapshot(CmxIrohEndpointSnapshot(
            runtimeGeneration: 2,
            state: .starting,
            identity: nil
        )))
        #expect(await events.next() == .snapshot(CmxIrohEndpointSnapshot(
            runtimeGeneration: 2,
            state: .active,
            identity: identity
        )))
        #expect(await events.next() == .recovered(previousGeneration: 1, newGeneration: 2))

        let configurations = await factory.observedConfigurations()
        #expect(configurations.count == 2)
        #expect(configurations[0].secretKey == configurations[1].secretKey)
        #expect(try await supervisor.activeEndpoint().identity() == identity)
    }

    @Test
    func foregroundHealthCheckPreservesAHealthyGeneration() async throws {
        let endpoint = TestIrohEndpoint(identity: identity)
        let factory = TestIrohEndpointFactory(endpoints: [endpoint])
        let supervisor = try CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: endpointConfiguration()
        )
        let active = try await supervisor.activate()

        let checked = try await supervisor.ensureHealthy()

        #expect(checked == active)
        #expect(await factory.observedConfigurations().count == 1)
        #expect(await endpoint.observedCloseCallCount() == 0)
    }

    @Test
    func foregroundHealthCheckRecreatesAStaleGeneration() async throws {
        let staleEndpoint = TestIrohEndpoint(identity: identity)
        let replacementEndpoint = TestIrohEndpoint(identity: identity)
        let factory = TestIrohEndpointFactory(
            endpoints: [staleEndpoint, replacementEndpoint]
        )
        let supervisor = try CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: endpointConfiguration()
        )
        _ = try await supervisor.activate()
        await staleEndpoint.setHealthy(false)

        let checked = try await supervisor.ensureHealthy()

        #expect(checked.state == .active)
        #expect(checked.runtimeGeneration == 2)
        #expect(await factory.observedConfigurations().count == 2)
        #expect(await staleEndpoint.observedCloseCallCount() == 1)
        #expect(try await supervisor.activeEndpoint().identity() == identity)
    }

    @Test
    func failedRelayRefreshPreservesLastKnownGoodBindConfiguration() async throws {
        let firstEndpoint = TestIrohEndpoint(identity: identity)
        let secondEndpoint = TestIrohEndpoint(identity: identity)
        await firstEndpoint.setRelayUpdateShouldFail(true)
        let factory = TestIrohEndpointFactory(endpoints: [firstEndpoint, secondEndpoint])
        let initialConfiguration = try endpointConfiguration()
        let supervisor = CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: initialConfiguration
        )
        _ = try await supervisor.activate()
        let replacement = try relayConfiguration(
            url: "https://usw1-1.relay.lawrence.cmux.iroh.link/",
            token: "bbbb"
        )

        await #expect(throws: TestIrohTransportError.relayUpdateFailed) {
            try await supervisor.replaceRelays([replacement])
        }
        await supervisor.deactivate()
        _ = try await supervisor.activate()

        let configurations = await factory.observedConfigurations()
        #expect(configurations.count == 2)
        #expect(configurations[1].relays == initialConfiguration.relays)
    }

    @Test
    func successfulRelayRefreshPreservesRequiredBindPolicyForRecovery() async throws {
        let firstEndpoint = TestIrohEndpoint(identity: identity)
        let secondEndpoint = TestIrohEndpoint(identity: identity)
        let factory = TestIrohEndpointFactory(endpoints: [firstEndpoint, secondEndpoint])
        let bindPolicy = try CmxIrohEndpointBindPolicy.required(
            CmxIrohBindAddress(ipAddress: "0.0.0.0", port: 49_152)
        )
        let initial = try endpointConfiguration(bindPolicy: bindPolicy)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: initial
        )
        _ = try await supervisor.activate()
        let replacement = try relayConfiguration(
            url: "https://usw1-1.relay.lawrence.cmux.iroh.link/",
            token: "bbbb"
        )

        try await supervisor.replaceRelays([replacement])
        await supervisor.deactivate()
        _ = try await supervisor.activate()

        let configurations = await factory.observedConfigurations()
        #expect(configurations.count == 2)
        #expect(configurations[1].bindPolicy == bindPolicy)
    }

    @Test
    func customProfileReplacementSurvivesEndpointRecovery() async throws {
        let firstEndpoint = TestIrohEndpoint(identity: identity)
        let secondEndpoint = TestIrohEndpoint(identity: identity)
        let factory = TestIrohEndpointFactory(endpoints: [firstEndpoint, secondEndpoint])
        let supervisor = CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: try endpointConfiguration()
        )
        _ = try await supervisor.activate()
        let custom = try CmxIrohCustomRelayProfile(
            relays: [
                CmxIrohCustomRelay(
                    url: "https://private.example.net:8443/",
                    authenticationToken: "private-token"
                ),
            ]
        )
        let profile = CmxIrohEndpointRelayProfile(customProfile: custom)

        try await supervisor.replaceRelayProfile(profile)
        await supervisor.deactivate()
        _ = try await supervisor.activate()

        #expect(await firstEndpoint.observedRelayProfileUpdates() == [profile])
        let configurations = await factory.observedConfigurations()
        #expect(configurations.count == 2)
        #expect(configurations[1].relayProfile == profile)
        #expect(configurations[1].secretKey == configurations[0].secretKey)
    }

    @Test
    func supersededRelayRefreshCannotPoisonAReplacementGeneration() async throws {
        let firstEndpoint = TestBlockingRelayUpdateEndpoint(identity: identity)
        let secondEndpoint = TestIrohEndpoint(identity: identity)
        let thirdEndpoint = TestIrohEndpoint(identity: identity)
        let factory = TestIrohEndpointFactory(
            endpoints: [firstEndpoint, secondEndpoint, thirdEndpoint]
        )
        let initialConfiguration = try endpointConfiguration()
        let supervisor = CmxIrohEndpointSupervisor(
            factory: factory,
            configuration: initialConfiguration
        )
        _ = try await supervisor.activate()
        var updateEvents = await firstEndpoint.updateEvents().makeAsyncIterator()
        let replacement = try relayConfiguration(
            url: "https://usw1-1.relay.lawrence.cmux.iroh.link/",
            token: "bbbb"
        )
        let refresh = Task {
            try await supervisor.replaceRelays([replacement])
        }
        _ = await updateEvents.next()

        await supervisor.deactivate()
        _ = try await supervisor.activate()
        await firstEndpoint.releaseUpdate()
        await #expect(throws: CmxIrohEndpointSupervisorError.superseded) {
            try await refresh.value
        }
        await supervisor.deactivate()
        _ = try await supervisor.activate()

        let configurations = await factory.observedConfigurations()
        #expect(configurations.count == 3)
        #expect(configurations[2].relays == initialConfiguration.relays)
    }

    private func endpointConfiguration(
        bindPolicy: CmxIrohEndpointBindPolicy = .ephemeral
    ) throws -> CmxIrohEndpointConfiguration {
        let relay = try relayConfiguration(
            url: "https://use1-1.relay.lawrence.cmux.iroh.link/",
            token: "aaaa"
        )
        return try CmxIrohEndpointConfiguration(
            secretKey: CmxIrohSecretKey(bytes: Data(repeating: 7, count: 32)),
            alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
            bindPolicy: bindPolicy,
            managedRelayURLs: [
                relay.url,
                "https://usw1-1.relay.lawrence.cmux.iroh.link/",
            ],
            relays: [relay]
        )
    }

    private func relayConfiguration(
        url: String,
        token: String
    ) throws -> CmxIrohRelayConfiguration {
        let now = Date(timeIntervalSince1970: 1_000)
        return try CmxIrohRelayConfiguration(
            url: url,
            token: token,
            expiresAt: now.addingTimeInterval(24 * 60 * 60),
            refreshAfter: now.addingTimeInterval(12 * 60 * 60),
            now: now
        )
    }
}
