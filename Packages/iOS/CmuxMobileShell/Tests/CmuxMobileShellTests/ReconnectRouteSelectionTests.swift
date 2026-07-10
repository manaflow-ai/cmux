import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

/// A restored/published Mac advertises both a `debug_loopback` route
/// (`127.0.0.1`, priority 0) and a `tailscale` route. On a physical phone the
/// loopback route names the phone itself and can never reach the Mac, so route
/// selection must prefer the real route there — otherwise tapping a saved Mac
/// dials the phone's own loopback and silently fails to connect.
@MainActor
@Suite struct ReconnectRouteSelectionTests {
    private func loopback(_ port: Int = 50906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: 0
        )
    }

    private func tailscale(_ port: Int = 50906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: port),
            priority: 10
        )
    }

    private func manualHost(_ port: Int = 50906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "manual_host",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: port),
            priority: 2
        )
    }

    private func legacyLANStoredAsTailscale(_ port: Int = 50906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "legacy_lan",
            kind: .tailscale,
            endpoint: .hostPort(host: "192.168.1.77", port: port),
            priority: 1
        )
    }

    @Test func physicalDevicePrefersRealRouteOverLowerPriorityLoopback() throws {
        let pick = MobileShellRouteSelection().firstReconnectHostPortRoute(
            [try loopback(), try tailscale()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "100.82.214.112") // tailscale, not the phone's 127.0.0.1
    }

    @Test func physicalDeviceFallsBackToLoopbackWhenItIsTheOnlyRoute() throws {
        // The on-device XCUITest mock host serves a real listener on 127.0.0.1.
        let pick = MobileShellRouteSelection().firstReconnectHostPortRoute(
            [try loopback()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "127.0.0.1")
    }

    @Test func simulatorKeepsLoopbackPriorityOrder() throws {
        // On the simulator 127.0.0.1 IS the host Mac, so priority order stands.
        let pick = MobileShellRouteSelection().firstReconnectHostPortRoute(
            [try loopback(), try tailscale()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: false
        )
        #expect(pick?.0 == "127.0.0.1")
    }

    @Test func physicalManualHostEntryDoesNotTrustLoopbackAlias() throws {
        let route = try MobileShellRouteSelection().manualHostRoute(
            host: "127.1",
            port: 50906,
            isPhysicalDevice: true
        )
        #expect(route.kind == .manualHost)
        #expect(!MobileShellRouteAuthPolicy().routeAllowsStackAuth(route))
    }

    @Test func legacyLANRouteStoredAsTailscaleBecomesManualHost() throws {
        let route = try MobileShellRouteSelection().manualHostRoute(
            host: "192.168.1.77",
            port: 50906,
            preserving: legacyLANStoredAsTailscale()
        )

        #expect(route.kind == .manualHost)
        #expect(route.endpoint == .hostPort(host: "192.168.1.77", port: 50906))
    }

    @Test func verifiedTailscaleSourcePreservesRouteKind() throws {
        let source = try tailscale()
        let route = try MobileShellRouteSelection().manualHostRoute(
            host: "100.82.214.112",
            port: 50906,
            preserving: source
        )

        #expect(route == source)
        #expect(route.kind == .tailscale)
    }

    @Test func invalidManualHostCannotConstructRoute() {
        do {
            _ = try MobileShellRouteSelection().manualHostRoute(
                host: "https://studio-mac.local/path",
                port: 50_906
            )
            Issue.record("Expected invalid manual host route construction to fail closed")
        } catch {}
    }

    @Test func reconnectCandidatesKeepFallbackRoutesAfterPreferredRoute() throws {
        let candidates = MobileShellComposite.reconnectHostPortRoutes(
            [try loopback(), try tailscale()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: false
        )

        #expect(candidates.map { $0.host } == ["127.0.0.1", "100.82.214.112"])
    }

    @Test func physicalDeviceCandidatesNeverIncludeLoopbackWhenRealRoutesExist() throws {
        // Route ITERATION dials every candidate, so the loopback tail entry
        // that single-pick selection never reached must not be in the list at
        // all: dialing 127.0.0.1 on a physical phone reaches whatever local
        // process is listening, and the manual attach path treats loopback as
        // trusted.
        let candidates = MobileShellComposite.reconnectHostPortRoutes(
            [try loopback(), try tailscale()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )

        #expect(candidates.map { $0.host } == ["100.82.214.112"])
    }

    @Test func physicalDeviceCandidatesUseLoopbackOnlyAsSoleSupportedRoute() throws {
        // The on-device XCUITest mock host serves a real listener on 127.0.0.1
        // and advertises no other route.
        let candidates = MobileShellComposite.reconnectHostPortRoutes(
            [try loopback()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )

        #expect(candidates.map { $0.host } == ["127.0.0.1"])
    }

    @Test func reconnectCandidatesDeduplicateEndpoints() throws {
        let duplicate = try CmxAttachRoute(
            id: "duplicate",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50906),
            priority: 0
        )

        let candidates = MobileShellComposite.reconnectHostPortRoutes(
            [duplicate, try tailscale()],
            supportedKinds: [.tailscale],
            preferNonLoopback: true
        )

        #expect(candidates.count == 1)
        #expect(candidates.first?.routeID == "duplicate")
    }

    private func magicDNS(_ port: Int = 50906) throws -> CmxAttachRoute {
        // A MagicDNS hostname route, advertised BEFORE the IP route by priority.
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "lawrences-macbook-pro-2.tail137216.ts.net", port: port),
            priority: 5
        )
    }

    @Test func physicalDevicePrefersIPLiteralOverMagicDNSHostname() throws {
        // The exact dogfood failure: a Mac advertises loopback, a MagicDNS
        // hostname (higher priority), and the raw tailscale IP. MagicDNS doesn't
        // resolve on the phone, so dialing the hostname times out; selection must
        // pick the IP literal so the secondary fetch / reconnect actually connects.
        let ip = try CmxAttachRoute(
            id: "tailscale_2",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50922),
            priority: 10
        )
        let pick = MobileShellRouteSelection().firstReconnectHostPortRoute(
            [try loopback(50922), try magicDNS(50922), ip],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "100.82.214.112")
    }

    @Test func magicDNSHostnameStillUsedWhenNoIPRouteExists() throws {
        // If the only non-loopback route is a hostname, still prefer it over
        // loopback on device (better than dialing the phone's own 127.0.0.1).
        let pick = MobileShellRouteSelection().firstReconnectHostPortRoute(
            [try loopback(50922), try magicDNS(50922)],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "lawrences-macbook-pro-2.tail137216.ts.net")
    }

    @Test func tailscaleDNSBeatsManualHostIPFallback() throws {
        let pick = MobileShellRouteSelection().firstReconnectHostPortRoute(
            [try loopback(50922), try manualHost(50922), try magicDNS(50922)],
            supportedKinds: [.debugLoopback, .manualHost, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "lawrences-macbook-pro-2.tail137216.ts.net")
    }

    @Test func tailscaleDNSBeatsLegacyLANRouteStoredAsTailscale() throws {
        let pick = MobileShellRouteSelection().firstReconnectHostPortRoute(
            [try loopback(50922), try legacyLANStoredAsTailscale(50922), try magicDNS(50922)],
            supportedKinds: [.debugLoopback, .manualHost, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "lawrences-macbook-pro-2.tail137216.ts.net")
    }

    @Test func ipLiteralHostClassification() {
        #expect(MobileShellRouteSelection().isIPLiteralHost("100.82.214.112"))
        #expect(MobileShellRouteSelection().isIPLiteralHost("127.0.0.1"))
        #expect(MobileShellRouteSelection().isIPLiteralHost("fd7a:115c:a1e0::4b36:d670"))
        #expect(MobileShellRouteSelection().isIPLiteralHost("::ffff:192.168.0.1"))
        #expect(MobileShellRouteSelection().isIPLiteralHost("[fd7a:115c:a1e0::4b36:d670]"))
        #expect(!MobileShellRouteSelection().isIPLiteralHost("lawrences-macbook-pro-2.tail137216.ts.net"))
        #expect(!MobileShellRouteSelection().isIPLiteralHost("example.com"))
        #expect(!MobileShellRouteSelection().isIPLiteralHost("my:host"))
        #expect(!MobileShellRouteSelection().isIPLiteralHost("100.82.214")) // too few octets
        #expect(!MobileShellRouteSelection().isIPLiteralHost("256.1.1.1")) // out of range
    }

    @Test func constrainedReconnectTicketMergesWithStoredRoutes() throws {
        let stale = try loopback(50906)
        let connected = try tailscale(50922)

        let merged = MobileShellComposite.mergedReconnectRoutes(
            ticketRoutes: [connected],
            storedRoutes: [stale, connected]
        )

        #expect(merged.map { $0.id }.contains(stale.id))
        #expect(merged.map { $0.id }.contains(connected.id))
        #expect(merged.count == 2)
    }

    @Test func reconnectActiveMacFallsThroughStaleRouteToGoodRouteInOneAttempt() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: box,
            failingPorts: [51000]
        )
        let store = try await makeReconnectStore(
            routes: [
                try loopbackRoute(id: "stale", port: 51000),
                try loopbackRoute(id: "good", port: 51001),
            ],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.debugLoopback]
            )
        )

        let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")

        #expect(connected)
        #expect(store.connectionState == .connected)
        #expect(factory.attemptedPorts() == [51000, 51001, 51001])
    }

    @Test func supersededReconnectGenerationAbortsRouteIteration() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = RouteRecordingTransportFactory(
            router: router,
            box: box,
            failingPorts: [51000],
            holdFirstFailingPort: 51000
        )
        let store = try await makeReconnectStore(
            routes: [
                try loopbackRoute(id: "stale", port: 51000),
                try loopbackRoute(id: "good", port: 51001),
            ],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.debugLoopback]
            )
        )

        let first = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        let firstRouteReached = try await pollUntil {
            factory.attemptedPorts() == [51000]
        }
        #expect(firstRouteReached)

        let second = Task { @MainActor in
            await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")
        }
        let secondConnected = await second.value
        factory.releaseHeldConnect()
        let firstConnected = await first.value

        #expect(!firstConnected)
        #expect(secondConnected)
        #expect(factory.attemptedPorts() == [51000, 51001, 51001])
    }

    func loopbackRoute(id: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: port
        )
    }

    func makeReconnectStore(
        routes: [CmxAttachRoute],
        runtime: any MobileSyncRuntime,
        reachability: any ReachabilityProviding = AlwaysOnlineReachability()
    ) async throws -> MobileShellComposite {
        let (pairedStore, _) = try makePairedMacStore()
        try await pairedStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: routes,
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date()
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: reachability,
            pairingHintDefaults: UserDefaults(suiteName: "reconnect-routes-\(UUID().uuidString)")!
        )
        await store.loadPairedMacs()
        return store
    }

    private func makePairedMacStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        return (store, directory)
    }
}

private enum RouteRecordingTransportError: Error {
    case routeFailed
}

final class RouteRecordingTransportFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let router: LivenessHostRouter
    private let box: TransportBox
    private let failingPorts: Set<Int>
    private let holdFirstFailingPort: Int?
    private let lock = NSLock()
    private var attempts: [Int] = []
    private var heldConnectConsumed = false
    private var heldConnectReleased = false
    private var heldConnectWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        router: LivenessHostRouter,
        box: TransportBox,
        failingPorts: Set<Int>,
        holdFirstFailingPort: Int? = nil
    ) {
        self.router = router
        self.box = box
        self.failingPorts = failingPorts
        self.holdFirstFailingPort = holdFirstFailingPort
    }

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        guard case let .hostPort(_, port) = route.endpoint else {
            throw RouteRecordingTransportError.routeFailed
        }
        let shouldHold = lock.withLock {
            attempts.append(port)
            if port == holdFirstFailingPort, !heldConnectConsumed {
                heldConnectConsumed = true
                return true
            }
            return false
        }
        if shouldHold {
            return HeldFailingConnectTransport(factory: self)
        }
        if failingPorts.contains(port) {
            throw RouteRecordingTransportError.routeFailed
        }
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }

    func attemptedPorts() -> [Int] {
        lock.withLock { attempts }
    }

    func releaseHeldConnect() {
        let waiters = lock.withLock {
            heldConnectReleased = true
            let waiters = heldConnectWaiters
            heldConnectWaiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilHeldConnectReleased() async {
        let shouldWait = lock.withLock {
            guard !heldConnectReleased else { return false }
            return true
        }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                guard !heldConnectReleased else { return true }
                heldConnectWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }
}

private actor HeldFailingConnectTransport: CmxByteTransport {
    private let factory: RouteRecordingTransportFactory

    init(factory: RouteRecordingTransportFactory) {
        self.factory = factory
    }

    func connect() async throws {
        await factory.waitUntilHeldConnectReleased()
        throw RouteRecordingTransportError.routeFailed
    }

    func receive() async throws -> Data? { nil }
    func send(_ data: Data) async throws {}
    func close() async {}
}
