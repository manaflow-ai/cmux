import Foundation
import Testing
@testable import CmuxMobileShell

/// Delayed replies and delayed events must not invalidate a working reader.
@MainActor
struct TerminalEventDeliveryLatencyTests {
    @Test(arguments: [false, true], [false, true])
    func deliveryDuringProbePreservesReader(
        agesBeforeReply: Bool,
        confirmingSilence: Bool
    ) async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = try await connect(router: router, box: box, clock: clock)
        defer { Task { await router.releaseAllHeld() } }
        let originalClient = store.remoteClient
        let originalGeneration = store.connectionGeneration
        let originalListener = try #require(store.debugTerminalEventListenerIDForTesting)
        let hostStatusCount = await router.count(of: "mobile.host.status")

        if confirmingSilence {
            clock.advance(by: 10)
            store.debugRunRenderGridLivenessCheckForTesting()
            await store.debugWaitForRenderGridLivenessCheckForTesting()
        }
        await router.delayProbeRequest(number: confirmingSilence ? 2 : 1)
        clock.advance(by: 10)
        store.debugRunRenderGridLivenessCheckForTesting()
        try #require(try await pollUntil { await router.heldRequestCount() == 1 })

        try await deliverHeartbeat(store: store, box: box, clock: clock)
        if agesBeforeReply {
            // A timestamp freshness check alone misses this ordering: the
            // event arrived during the probe, then the probe reply was delayed.
            clock.advance(by: 10)
        }
        await router.releaseNextHeld()
        await store.debugWaitForRenderGridLivenessCheckForTesting()

        #expect(store.debugTerminalEventListenerIDForTesting == originalListener)
        #expect(await router.count(of: "mobile.events.subscribe") == 1)
        #expect(await router.count(of: "mobile.host.status") == hostStatusCount)
        #expect(store.remoteClient === originalClient)
        #expect(store.connectionGeneration == originalGeneration)
        #expect(store.connectionState == .connected)
    }

    @Test
    func deliveryDuringTransportStatusCheckInvalidatesFailure() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = try await connect(
            router: router, box: box, clock: clock,
            probeTimeoutNanoseconds: 50_000_000
        )
        let transport = try #require(box.get())
        defer {
            Task {
                await transport.releaseHeldLivenessCheck()
                await router.releaseAllHeld()
            }
        }
        let originalListener = try #require(store.debugTerminalEventListenerIDForTesting)
        let originalClient = store.remoteClient
        let originalGeneration = store.connectionGeneration
        await router.setHoldSubscribe(true)
        await router.holdProbeRequest(number: 1)
        await router.holdProbeRequest(number: 2)
        clock.advance(by: 10)
        store.debugRunRenderGridLivenessCheckForTesting()
        await store.debugWaitForRenderGridLivenessCheckForTesting()

        await transport.holdNextLivenessCheck()
        store.debugRunRenderGridLivenessCheckForTesting()
        try #require(try await pollUntil { await transport.hasHeldLivenessCheck() })
        try await deliverHeartbeat(store: store, box: box, clock: clock)
        clock.advance(by: 10)
        store.debugRunRenderGridLivenessCheckForTesting()
        #expect(await router.count(of: "mobile.events.probe") == 2,
                "a status check still owns the single in-flight probe slot")
        await transport.releaseHeldLivenessCheck()
        await store.debugWaitForRenderGridLivenessCheckForTesting()

        #expect(store.debugTerminalEventListenerIDForTesting == originalListener)
        #expect(store.remoteClient === originalClient)
        #expect(store.connectionGeneration == originalGeneration)
        #expect(store.connectionState == .connected)
    }

    @Test
    func unknownTransportStatusDoesNotReplaceConnection() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = try await makeConnectedStore(
            router: router, box: box, clock: clock,
            probeTimeoutNanoseconds: 50_000_000,
            observesTransportLiveness: false
        )
        defer { Task { await router.releaseAllHeld() } }
        try #require(await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        try #require(try await pollUntil { store.terminalEventSubscriptionIsValidated })
        let originalClient = try #require(store.remoteClient)
        let originalGeneration = store.connectionGeneration
        let originalListener = try #require(store.debugTerminalEventListenerIDForTesting)
        #expect(await originalClient.isTransportClosed() == nil)
        await router.setHoldSubscribe(true)
        await router.holdProbeRequest(number: 1)
        await router.holdProbeRequest(number: 2)

        clock.advance(by: 10)
        store.debugRunRenderGridLivenessCheckForTesting()
        await store.debugWaitForRenderGridLivenessCheckForTesting()
        store.debugRunRenderGridLivenessCheckForTesting()
        await store.debugWaitForRenderGridLivenessCheckForTesting()

        #expect(store.debugTerminalEventListenerIDForTesting != originalListener,
                "sustained silence should still repair the output reader")
        #expect(store.remoteClient === originalClient)
        #expect(store.connectionGeneration == originalGeneration)
        #expect(store.connectionState == .connected,
                "missing native status is not positive evidence of a dead connection")
    }

    @Test
    func slowProbeExtendsGraceAndDeliveryCancelsSuspicion() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = try await connect(router: router, box: box, clock: clock)
        defer { Task { await router.releaseAllHeld() } }

        let originalListener = try #require(store.debugTerminalEventListenerIDForTesting)

        await router.delayProbeRequest(number: 1)
        clock.advance(by: 10)
        store.debugRunRenderGridLivenessCheckForTesting()
        try #require(try await pollUntil { await router.heldRequestCount() == 1 })
        clock.advance(by: 6)
        await router.releaseNextHeld()
        await store.debugWaitForRenderGridLivenessCheckForTesting()
        #expect(store.debugTerminalEventListenerIDForTesting == originalListener)
        #expect(await router.count(of: "mobile.events.subscribe") == 1)

        // A six-second probe earns twelve seconds of delivery grace. Ten
        // seconds after its reply is too early for another recovery decision.
        clock.advance(by: 10)
        store.debugRunRenderGridLivenessCheckForTesting()
        await store.debugWaitForRenderGridLivenessCheckForTesting()
        #expect(await router.count(of: "mobile.events.probe") == 1)
        #expect(await router.count(of: "mobile.events.subscribe") == 1)

        try await deliverHeartbeat(store: store, box: box, clock: clock)
        clock.advance(by: 10)
        store.debugRunRenderGridLivenessCheckForTesting()
        await store.debugWaitForRenderGridLivenessCheckForTesting()
        #expect(await router.count(of: "mobile.events.probe") == 2)
        #expect(store.debugTerminalEventListenerIDForTesting == originalListener)
        #expect(await router.count(of: "mobile.events.subscribe") == 1,
                "delivery cancels the earlier suspicion; another gap starts a fresh grace period")
    }

    @Test
    func lostRegistrationStillReplaysAfterQueuedDelivery() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = try await connect(router: router, box: box, clock: clock)
        defer { Task { await router.releaseAllHeld() } }
        let collector = OutputCollector()
        collector.mount(store: store, surfaceID: "live-terminal")
        defer { collector.unmount() }
        try await waitForReplayResponsesServed(1, router: router, "mount replay must finish")
        let hostStatusCount = await router.count(of: "mobile.host.status")

        await router.dropSubscription()
        await router.delayProbeRequest(number: 1)
        clock.advance(by: 10)
        store.debugRunRenderGridLivenessCheckForTesting()
        try #require(try await pollUntil { await router.heldRequestCount() == 1 })
        // This queued event proves delivery resumed, but does not repair
        // updates lost while the host had no registration.
        try await deliverHeartbeat(store: store, box: box, clock: clock)
        await router.releaseNextHeld()
        await store.debugWaitForRenderGridLivenessCheckForTesting()

        #expect(await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2))
        #expect(await router.count(of: "mobile.events.subscribe") == 2)
        #expect(await router.count(of: "mobile.host.status") == hostStatusCount)
    }

    private func connect(
        router: LivenessHostRouter,
        box: TransportBox,
        clock: TestClock,
        probeTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws -> MobileShellComposite {
        await router.setCapabilities([
            "events.v1", "terminal.bytes.v1", "terminal.render_grid.v1",
            "terminal.replay.v1", "terminal.events.heartbeat.v1",
        ])
        let store = try await makeConnectedStore(
            router: router, box: box, clock: clock,
            probeTimeoutNanoseconds: probeTimeoutNanoseconds
        )
        try #require(await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1))
        try #require(try await pollUntil { await router.successfulSubscribeCount() == 1 })
        return store
    }

    private func deliverHeartbeat(
        store: MobileShellComposite,
        box: TransportBox,
        clock: TestClock
    ) async throws {
        clock.advance(by: 1)
        let expectedTime = clock.now
        let transport = try #require(box.get())
        await transport.deliver(try terminalEventHeartbeatFrame())
        try #require(try await pollUntil { store.lastTerminalEventAt == expectedTime })
    }
}
