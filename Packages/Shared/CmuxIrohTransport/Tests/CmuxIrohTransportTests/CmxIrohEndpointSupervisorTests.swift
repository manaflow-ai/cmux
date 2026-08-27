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

    @Test("successful relay replacement publishes a reachability change")
    func successfulRelayReplacementPublishesNetworkChange() async throws {
        let relayHint = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://usw1-1.relay.lawrence.cmux.iroh.link/",
            source: .native,
            privacyScope: .publicInternet
        )
        let endpoint = TestIrohEndpoint(
            identity: identity,
            pathHintsAfterRelayReplacement: [relayHint]
        )
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try endpointConfiguration()
        )
        let changes = HostRuntimeLANRefreshRecorder()
        let events = await supervisor.events()
        let observation = Task {
            for await event in events {
                if case .networkChanged = event {
                    await changes.record()
                }
            }
        }
        _ = try await supervisor.activate()
        let replacement = try relayConfiguration(
            url: "https://usw1-1.relay.lawrence.cmux.iroh.link/",
            token: "bbbb"
        )

        try await supervisor.replaceRelays([replacement])

        let emittedChange = await changes.waitForRefresh(timeout: .seconds(1))
        #expect(
            emittedChange,
            "A successful relay replacement must publish a network-change event"
        )
        observation.cancel()
        await supervisor.deactivate()
    }

    @Test("relay credential rotation does not republish an unchanged address")
    func unchangedRelayAddressDoesNotPublishNetworkChange() async throws {
        let endpoint = TestIrohEndpoint(identity: identity)
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: try endpointConfiguration()
        )
        let changes = HostRuntimeLANRefreshRecorder()
        let events = await supervisor.events()
        let observation = Task {
            for await event in events {
                if case .networkChanged = event {
                    await changes.record()
                }
            }
        }
        _ = try await supervisor.activate()
        let replacement = try relayConfiguration(
            url: "https://usw1-1.relay.lawrence.cmux.iroh.link/",
            token: "bbbb"
        )

        try await supervisor.replaceRelays([replacement])

        let emittedChange = await changes.waitForRefresh(timeout: .milliseconds(50))
        #expect(
            !emittedChange,
            "Rotating credentials without changing the published address must not refresh policy"
        )
        observation.cancel()
        await supervisor.deactivate()
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

    @Test("an already-online generation replays relay readiness")
    func alreadyOnlineGenerationIsImmediatelyReady() async throws {
        let endpoint = TestIrohEndpoint(identity: identity)
        let supervisor = try CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: endpointConfiguration()
        )
        _ = try await supervisor.activate()
        await endpoint.emit(.online)

        try await supervisor.waitForUsableHomeRelay(timeout: .seconds(1))

        #expect(await supervisor.hasUsableHomeRelay())
    }

    @Test("a strict custom relay profile participates in readiness")
    func customRelayProfileWaitsForOnlineSignal() async throws {
        let endpoint = TestIrohEndpoint(identity: identity)
        let custom = try CmxIrohCustomRelayProfile(relays: [
            CmxIrohCustomRelay(
                url: "https://private.example.net:8443/",
                authenticationToken: "private-token"
            ),
        ])
        let base = try endpointConfiguration()
        let configuration = CmxIrohEndpointConfiguration(
            secretKey: base.secretKey,
            alpns: base.alpns,
            bindPolicy: base.bindPolicy,
            relayProfile: CmxIrohEndpointRelayProfile(customProfile: custom)
        )
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: configuration
        )
        _ = try await supervisor.activate()
        #expect(await supervisor.hasConfiguredRelay())
        let wait = Task {
            try await supervisor.waitForUsableHomeRelay(timeout: .seconds(1))
        }
        await Task.yield()

        await endpoint.emit(.online)

        try await wait.value
        #expect(await supervisor.hasUsableHomeRelay())
    }

    @Test("relay replacement waits for the next online signal")
    func relayReplacementWaitsForOnlineSignal() async throws {
        let endpoint = TestIrohEndpoint(identity: identity)
        let configuration = try endpointConfiguration()
        let supervisor = CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: configuration
        )
        _ = try await supervisor.activate()
        await endpoint.emit(.online)
        try await supervisor.waitForUsableHomeRelay(timeout: .seconds(1))
        try await supervisor.replaceRelayProfile(configuration.relayProfile)
        #expect(!(await supervisor.hasUsableHomeRelay()))

        let wait = Task {
            try await supervisor.waitForUsableHomeRelay(timeout: .seconds(1))
        }
        await Task.yield()
        await endpoint.emit(.online)

        try await wait.value
        #expect(await supervisor.hasUsableHomeRelay())
    }

    @Test("relay readiness has a bounded timeout")
    func relayReadinessTimesOut() async throws {
        let endpoint = TestIrohEndpoint(identity: identity)
        let supervisor = try CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: endpointConfiguration()
        )
        _ = try await supervisor.activate()

        await #expect(throws: CmxIrohEndpointSupervisorError.relayReadinessTimedOut) {
            try await supervisor.waitForUsableHomeRelay(timeout: .milliseconds(20))
        }
    }

    @Test("relay readiness cancellation removes its waiter")
    func relayReadinessCancellationPropagates() async throws {
        let endpoint = TestIrohEndpoint(identity: identity)
        let supervisor = try CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            configuration: endpointConfiguration()
        )
        _ = try await supervisor.activate()
        let wait = Task {
            try await supervisor.waitForUsableHomeRelay(timeout: .seconds(5))
        }
        await Task.yield()

        wait.cancel()

        await #expect(throws: CancellationError.self) {
            try await wait.value
        }
    }

    @Test("a replacement generation supersedes the prior relay waiter")
    func replacementGenerationSupersedesRelayReadiness() async throws {
        let first = TestIrohEndpoint(identity: identity)
        let second = TestIrohEndpoint(identity: identity)
        let supervisor = try CmxIrohEndpointSupervisor(
            factory: TestIrohEndpointFactory(endpoints: [first, second]),
            configuration: endpointConfiguration()
        )
        _ = try await supervisor.activate()
        let wait = Task {
            try await supervisor.waitForUsableHomeRelay(timeout: .seconds(5))
        }
        await Task.yield()

        await first.emit(.closedUnexpectedly)

        await #expect(throws: CmxIrohEndpointSupervisorError.superseded) {
            try await wait.value
        }
        let replacementIdentity = try await supervisor.activeEndpoint().identity()
        #expect(replacementIdentity == identity)
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
