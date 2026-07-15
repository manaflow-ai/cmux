import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct IrohStoredReconnectRegressionTests {
    @Test func storedReconnectPinsIrohAndExcludesRawFallbacks() throws {
        let routes = MobileShellComposite.storedReconnectRoutes(
            [try loopback(), try tailscale(), try iroh()],
            supportedKinds: [.iroh, .tailscale, .debugLoopback],
            preferNonLoopback: true
        )

        #expect(routes.map(\.kind) == [.iroh])
        #expect(MobileShellComposite.reconnectHostPortRoutes(
            [try tailscale(), try iroh()],
            supportedKinds: [.iroh, .tailscale],
            preferNonLoopback: true
        ).isEmpty)
    }

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
    }

    @Test func rejectedIrohReconnectNeverDowngradesToRawTailscale() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        let factory = KindRecordingTransportFactory(
            router: router,
            box: box,
            failingKinds: [.iroh]
        )
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

    @Test func manualFallbackReconnectAdoptsAuthenticatedMacID() async throws {
        let clock = TestClock()
        let router = LivenessHostRouter()
        let box = TransportBox()
        await router.failRequests(
            method: "mobile.attach_ticket.create",
            code: "method_not_found",
            message: "unsupported"
        )
        let store = try await makeReconnectStore(
            routes: [try loopbackRoute(id: "legacy", port: 51_003)],
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(router: router, box: box),
                now: { clock.now },
                supportedRouteKinds: [.debugLoopback]
            )
        )

        #expect(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1"))
        #expect(store.connectionState == .connected)
        #expect(store.activeTicket?.macDeviceID == "test-mac")
        #expect(store.foregroundMacDeviceID == "test-mac")
    }

    @Test func exhaustedRouteDisconnectsCreatedClient() async throws {
        let clock = TestClock()
        let factory = CloseRecordingTransportFactory()
        let store = try await makeReconnectStore(
            routes: [try loopbackRoute(id: "failing", port: 51_004)],
            runtime: LivenessTestRuntime(
                transportFactory: factory,
                now: { clock.now },
                supportedRouteKinds: [.debugLoopback]
            )
        )

        #expect(!(await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")))
        #expect(try await pollUntil { factory.closeCount() == 1 })
    }

    private func loopback(_ port: Int = 50_906) throws -> CmxAttachRoute {
        try loopbackRoute(id: "debug_loopback", port: port)
    }

    private func loopbackRoute(id: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: port
        )
    }

    private func tailscale(_ port: Int = 50_906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: port),
            priority: 10
        )
    }

    private func iroh(priority: Int = 0) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                id: "peer-1",
                relayHint: nil,
                directAddrs: [],
                relayURL: "https://relay.example"
            ),
            priority: priority
        )
    }

    private func makeReconnectStore(
        routes: [CmxAttachRoute],
        runtime: any MobileSyncRuntime
    ) async throws -> MobileShellComposite {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
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
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(suiteName: "iroh-reconnect-\(UUID().uuidString)")!
        )
        await store.loadPairedMacs()
        return store
    }
}

private enum IrohReconnectRouteError: Error {
    case routeFailed
}

private final class KindRecordingTransportFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let router: LivenessHostRouter
    private let box: TransportBox
    private let failingKinds: Set<CmxAttachTransportKind>
    private let lock = NSLock()
    private var attempts: [CmxAttachTransportKind] = []

    init(
        router: LivenessHostRouter,
        box: TransportBox,
        failingKinds: Set<CmxAttachTransportKind> = []
    ) {
        self.router = router
        self.box = box
        self.failingKinds = failingKinds
    }

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        lock.withLock { attempts.append(route.kind) }
        if failingKinds.contains(route.kind) {
            throw IrohReconnectRouteError.routeFailed
        }
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }

    func attemptedKinds() -> [CmxAttachTransportKind] {
        lock.withLock { attempts }
    }
}

private final class CloseRecordingTransportFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var closes = 0

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        CloseRecordingTransport(factory: self)
    }

    func recordClose() {
        lock.withLock { closes += 1 }
    }

    func closeCount() -> Int {
        lock.withLock { closes }
    }
}

private actor CloseRecordingTransport: CmxByteTransport {
    private let factory: CloseRecordingTransportFactory

    init(factory: CloseRecordingTransportFactory) {
        self.factory = factory
    }

    func connect() async throws {}
    func receive() async throws -> Data? { nil }

    func send(_ data: Data) async throws {
        throw IrohReconnectRouteError.routeFailed
    }

    func close() async {
        factory.recordClose()
    }
}
