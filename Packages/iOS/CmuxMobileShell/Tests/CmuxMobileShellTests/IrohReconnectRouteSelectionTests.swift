import CMUXMobileCore
import Testing
@testable import CmuxMobileShell

@MainActor
extension ReconnectRouteSelectionTests {
    @Test func reconnectActiveMacUsesPersistedIrohBeforeNetworkFallback() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let store = try await makeReconnectStore(
            routes: [try tailscale(), try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            )
        )

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(store.connectionState == .connected)
        #expect(factory.attemptedKinds() == [.iroh])
        #expect(store.activeRoute?.kind == .iroh)
        #expect(await router.workspaceIDs(for: "workspace.list") == [nil])
        #expect(store.workspaces.map(\.rpcWorkspaceID.rawValue) == ["live-workspace"])
    }

    @Test func rejectedIrohReconnectNeverDowngradesToRawTailscale() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box, failingKinds: [.iroh])
        let store = try await makeReconnectStore(
            routes: [try tailscale(), try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            )
        )

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(store.connectionState == .disconnected)
        #expect(factory.attemptedKinds() == [.iroh])
    }

    @Test func legacyMacWithoutIrohFailsClosedInsteadOfSendingBearerOverTCP() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let store = try await makeReconnectStore(
            routes: [try tailscale()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            )
        )

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(factory.attemptedKinds().isEmpty)
    }

    @Test func switchingToIrohCapableMacUsesPinnedIrohRoute() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(router: router, box: box)
        let store = try await makeReconnectStore(
            routes: [try tailscale(), try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.iroh, .tailscale]
            )
        )

        #expect(await store.switchToMac(macDeviceID: "test-mac"))
        #expect(factory.attemptedKinds() == [.iroh])
        #expect(store.activeRoute?.kind == .iroh)
    }

    @Test func foregroundResumeRedialsDeadIrohSessionBeforeUserAction() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let store = try await makeReconnectStore(
            routes: [try iroh()],
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(router: router, box: box),
                now: { clock.now },
                supportedRouteKinds: [.iroh]
            )
        )
        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        let firstTransport = try #require(box.get())
        await firstTransport.close()

        store.suspendForegroundRefresh()
        clock.advance(by: 61)
        store.resumeForegroundRefresh()

        let recoveryTask = try #require(store.foregroundConnectionRecoveryTask)
        await recoveryTask.value
        let currentTransport = try #require(box.get())
        #expect(currentTransport !== firstTransport)
        #expect(store.connectionState == .connected)
        #expect(store.activeRoute?.kind == .iroh)
    }

    @Test func storedReconnectPinsIrohAndExcludesRawFallbacks() throws {
        let routes = MobileShellComposite.storedReconnectRoutes(
            [try loopback(), try tailscale(), try iroh()],
            supportedKinds: [.iroh, .tailscale, .debugLoopback],
            preferNonLoopback: true
        )

        #expect(routes.map(\.kind) == [.iroh])
        guard case let .peer(identity, hints) = routes[0].endpoint else {
            Issue.record("Expected pinned Iroh route")
            return
        }
        #expect(identity.endpointID == String(repeating: "a", count: 64))
        #expect(hints.count == 1)
        #expect(hints[0].value == "100.82.214.112:50906")
        #expect(hints[0].source == .tailscale)
        #expect(hints[0].use == .fallbackOnly)
    }
}
