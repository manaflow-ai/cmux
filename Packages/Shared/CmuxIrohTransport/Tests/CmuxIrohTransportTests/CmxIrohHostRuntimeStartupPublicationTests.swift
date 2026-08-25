import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxIrohTransport

extension CmxIrohHostRuntime {
    /// Awaits the startup ready gate and every refresh round it scheduled, so
    /// tests observe the settled post-reconcile state deterministically.
    func waitForInitialPublicationForTesting() async {
        await initialPublicationTask?.value
        while let task = registrationRefreshTask {
            await task.value
        }
    }
}

extension CmxIrohHostRuntimeTests {
    /// Regression for the advertise-before-ready warm-up race
    /// (https://github.com/manaflow-ai/cmux/issues/9724): a Mac must not
    /// publish its binding or route hints while its home relay is still
    /// warming up, because clients immediately burn doomed dials against an
    /// endpoint that cannot yet accept them. The binding and route may only
    /// be published once the relay is usable, with the post-relay hints, and
    /// exactly once.
    @Test("binding publication waits for a usable home relay")
    func bindingPublicationWaitsForUsableHomeRelay() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now)
        let readyBinding = try HostRuntimeFixture.binding(
            endpointID: fixture.endpointID.endpointID,
            bindingID: fixture.binding.bindingID,
            publicHintObservedAt: now,
            publicHintExpiresAt: now.addingTimeInterval(60 * 60)
        )
        let relayHint = try #require(readyBinding.pathHints.first)
        let readyDiscovery = try HostRuntimeFixture.discovery(
            binding: readyBinding,
            relays: HostRuntimeFixture.relayURLs
        )
        // The endpoint gains its usable relay hint only after the relay
        // credential coordinator installs the first credential, exactly like
        // a cold production launch.
        let endpoint = TestIrohEndpoint(
            identity: fixture.endpointID,
            pathHintsAfterRelayReplacement: [relayHint]
        )
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            subsequentRegistrationBindings: [readyBinding],
            subsequentDiscoveries: [readyDiscovery]
        )
        let bindings = HostRuntimeBindingRecorder()
        let routes = HostRuntimeRouteRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { now },
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() },
            handleRoute: { binding, pathHints in
                await routes.record(binding: binding, pathHints: pathHints)
            }
        )

        try await runtime.start()

        // No usable home relay exists yet: the Mac must not be
        // discoverable-but-undialable.
        #expect(await bindings.count() == 0)
        #expect(await routes.values().isEmpty)
        #expect(await runtime.snapshot().state == .active)

        // The relay comes up through the normal credential installation path.
        // Publication must follow, exactly once, with the post-relay hints.
        #expect(await bindings.waitForCount(1, timeout: .seconds(5)))
        let republished = await routes.values()
        #expect(republished.map(\.binding.bindingID) == [fixture.binding.bindingID])
        #expect(republished.map(\.pathHints) == [[relayHint]])
        #expect(!(await bindings.waitForCount(2, timeout: .milliseconds(300))))

        await runtime.stop()
    }

    /// Cache-first activation: a persisted verified policy for the same
    /// binding makes the Mac dialable immediately. The live broker round is
    /// only a background reconcile, so start() completes while the broker has
    /// not yet answered at all.
    @Test("cache-first start becomes ready without a live broker response")
    func cacheFirstStartBecomesReadyWithoutALiveBrokerResponse() async throws {
        let fixture = try HostRuntimeFixture()
        let cachedFixture = try fixture.cachedPolicyFixture()
        let now = cachedFixture.now
        let cachedPolicy = try cachedFixture.policy()
        let registrationGate = HostRuntimeRegistrationGate()
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery,
            registrationHook: {
                await registrationGate.waitOnce()
                return true
            }
        )
        let bindings = HostRuntimeBindingRecorder()
        let routes = HostRuntimeRouteRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                try fixture.relayReadyEndpoint(),
            ]),
            broker: broker,
            configuration: fixture.configuration(cachedHostPolicy: cachedPolicy),
            pendingRevocations: fixture.pendingRevocations(),
            now: { now },
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() },
            handleRoute: { binding, pathHints in
                await routes.record(binding: binding, pathHints: pathHints)
            }
        )

        try await runtime.start()

        #expect(await runtime.snapshot().state == .active)
        #expect(await runtime.snapshot().bindingID == cachedPolicy.binding.bindingID)
        #expect(await runtime.lanAdvertisementContext()?.rendezvous == cachedPolicy.lanRendezvous)
        // The cached route identity is refreshed, never unpublished, but no
        // fresh binding may be published while the live round is unanswered.
        #expect(await routes.values() == [
            .init(binding: cachedPolicy.binding, pathHints: []),
        ])
        #expect(await broker.waitForRegistrationCount(1, timeout: .seconds(5)))
        #expect(await runtime.snapshot().state == .active)
        #expect(await bindings.count() == 0)

        await registrationGate.open()
        await runtime.waitForInitialPublicationForTesting()

        #expect(await bindings.count() == 1)
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    /// The late live policy reconciles onto a cache-first activation: the
    /// same binding is re-verified and the fresh broker route hints replace
    /// the empty cached ones.
    @Test("late live policy reconciles a cache-first activation")
    func lateLivePolicyReconcilesCacheFirstActivation() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now, publicHintLifetime: 60 * 60)
        let discoveredHint = try #require(fixture.binding.pathHints.first)
        let cachedFixture = try fixture.cachedPolicyFixture()
        let cachedPolicy = try cachedFixture.policy()
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let bindings = HostRuntimeBindingRecorder()
        let routes = HostRuntimeRouteRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [
                try fixture.relayReadyEndpoint(),
            ]),
            broker: broker,
            configuration: fixture.configuration(cachedHostPolicy: cachedPolicy),
            pendingRevocations: fixture.pendingRevocations(),
            now: { now },
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() },
            handleRoute: { binding, pathHints in
                await routes.record(binding: binding, pathHints: pathHints)
            }
        )

        try await runtime.start()
        await runtime.waitForInitialPublicationForTesting()

        #expect(await broker.observedRegistrationCount() == 1)
        #expect(await bindings.count() == 1)
        #expect(await routes.values() == [
            .init(binding: cachedPolicy.binding, pathHints: []),
            .init(
                binding: CmxIrohBrokerBindingMetadata(binding: fixture.binding),
                pathHints: [discoveredHint]
            ),
        ])
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    /// A relay-readiness timeout must never publish. The gate keeps retrying
    /// the readiness wait on the injected clock; once the relay becomes
    /// usable, exactly one publication follows.
    @Test("readiness timeouts keep the binding unpublished until the relay succeeds")
    func readinessTimeoutsKeepBindingUnpublishedUntilRelaySucceeds() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now)
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let clock = HostRegistrationRenewalClock(now: now)
        let bindings = HostRuntimeBindingRecorder()
        let routes = HostRuntimeRouteRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { clock.now() },
            registrationClock: clock,
            registrationRetryJitter: { 0 },
            relayReadinessTimeout: .milliseconds(20),
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() },
            handleRoute: { binding, pathHints in
                await routes.record(binding: binding, pathHints: pathHints)
            }
        )

        try await runtime.start()
        #expect(await bindings.count() == 0)

        // First readiness timeout: still unpublished, backoff armed.
        await clock.waitUntilSleepCount(1)
        #expect(await bindings.count() == 0)
        #expect(await routes.values().isEmpty)
        clock.advance(to: try #require(clock.observedSleepDeadlines().last))

        // Second readiness timeout: still unpublished.
        await clock.waitUntilSleepCount(2)
        #expect(await bindings.count() == 0)

        // The home relay comes up. Publication must follow, exactly once.
        await endpoint.emit(.online)

        #expect(await bindings.waitForCount(1, timeout: .seconds(5)))
        #expect(!(await bindings.waitForCount(2, timeout: .milliseconds(300))))
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }

    /// A relay that never becomes usable must leave the endpoint permanently
    /// unpublished: no handleBinding, no handleRoute, no extra broker rounds.
    @Test("readiness that never succeeds never publishes")
    func readinessThatNeverSucceedsNeverPublishes() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try HostRuntimeFixture(now: now)
        let endpoint = TestIrohEndpoint(identity: fixture.endpointID)
        let broker = TestIrohHostBroker(
            registrationBinding: fixture.binding,
            discovery: fixture.discovery
        )
        let clock = HostRegistrationRenewalClock(now: now)
        let bindings = HostRuntimeBindingRecorder()
        let routes = HostRuntimeRouteRecorder()
        let runtime = CmxIrohHostRuntime(
            factory: TestIrohEndpointFactory(endpoints: [endpoint]),
            broker: broker,
            configuration: fixture.configuration,
            pendingRevocations: fixture.pendingRevocations(),
            now: { clock.now() },
            registrationClock: clock,
            registrationRetryJitter: { 0 },
            relayReadinessTimeout: .milliseconds(20),
            handleTransport: { session, _ in await session.close() },
            handleBinding: { _, _, _ in await bindings.record() },
            handleRoute: { binding, pathHints in
                await routes.record(binding: binding, pathHints: pathHints)
            }
        )

        try await runtime.start()

        for cycle in 1 ... 3 {
            await clock.waitUntilSleepCount(cycle)
            #expect(await bindings.count() == 0)
            #expect(await routes.values().isEmpty)
            clock.advance(to: try #require(clock.observedSleepDeadlines().last))
        }

        #expect(await bindings.count() == 0)
        #expect(await routes.values().isEmpty)
        #expect(await broker.observedRegistrationCount() == 1)
        #expect(await runtime.snapshot().state == .active)
        await runtime.stop()
    }
}
