import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileTransport

@Suite struct CmxIrohByteTransportTests {
    @Test func routeFactoryRegistersIrohPeerRoutes() throws {
        let ffi = FakeIrohFFIClient()
        let manager = CmxIrohEndpointManager(
            keyProvider: CmxIrohSecretKeyProvider(
                store: InMemoryIrohSecretStore(),
                generate: { Data(repeating: 7, count: 32) }
            ),
            ffiClient: ffi
        )
        let irohFactory = CmxIrohByteTransportFactory(endpointManager: manager, ffiClient: ffi)
        let factory = try CmxRouteTransportFactory([
            CmxRouteTransportFactoryRegistration(kind: .iroh, factory: irohFactory),
        ])
        let route = try peerRoute(endpointID: "peer-a")

        let transport = try factory.makeTransport(for: route)

        #expect(factory.supportedKinds == [.iroh])
        #expect(transport is CmxIrohByteTransport)
    }

    @Test func secretKeyProviderPersistsGeneratedKey() throws {
        let store = InMemoryIrohSecretStore()
        let generateCount = LockedCounter()
        let provider = CmxIrohSecretKeyProvider(store: store) {
            generateCount.increment()
            return Data(repeating: 3, count: 32)
        }

        let first = try provider.secretKey()
        let second = try provider.secretKey()

        #expect(first == Data(repeating: 3, count: 32))
        #expect(second == first)
        #expect(generateCount.value() == 1)
        #expect(try store.loadSecretKey() == first)
    }

    @Test func connectFailureKindMapsFromFfiCodes() {
        #expect(CmxIrohErrorKind.timedOut.connectFailureKind == .timedOut)
        #expect(CmxIrohErrorKind.connectionRefused.connectFailureKind == .connectionRefused)
        #expect(CmxIrohErrorKind.hostUnreachable.connectFailureKind == .hostUnreachable)
        #expect(CmxIrohErrorKind.permissionDenied.connectFailureKind == .permissionDenied)
        #expect(CmxIrohErrorKind.dnsFailed.connectFailureKind == .dnsFailed)
        #expect(CmxIrohErrorKind.secureChannelFailed.connectFailureKind == .secureChannelFailed)
        #expect(CmxIrohErrorKind.internalFailure.connectFailureKind == .generic)
    }

    @Test func irohPingerDialsPeerRouteAndCloses() async throws {
        let ffi = FakeIrohFFIClient()
        let manager = CmxIrohEndpointManager(
            keyProvider: CmxIrohSecretKeyProvider(
                store: InMemoryIrohSecretStore(),
                generate: { Data(repeating: 9, count: 32) }
            ),
            ffiClient: ffi
        )
        let factory = CmxIrohByteTransportFactory(endpointManager: manager, ffiClient: ffi)
        let pinger = CmxNetworkRoutePinger(irohFactory: factory)

        let result = await pinger.ping(try peerRoute(endpointID: "peer-ping"), timeoutNanoseconds: 1_000_000_000)

        guard case .reachable = result else {
            Issue.record("expected reachable, got \(result)")
            return
        }
        #expect(ffi.connectedPeerIDs() == ["peer-ping"])
        #expect(ffi.closedConnectionCount() == 1)
    }

    @Test func localIrohLoopbackEchoesBytes() async throws {
        let packageURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let xcframeworkURL = packageURL.appending(path: "../../../CmuxIrohFFI.xcframework").standardizedFileURL
        guard FileManager.default.fileExists(atPath: xcframeworkURL.path) else {
            return
        }

        let ffi = CmxIrohSystemFFIClient()
        let serverKey = try ffi.generateSecretKey()
        let clientKey = try ffi.generateSecretKey()
        let server = try ffi.bindEndpoint(
            secretKey: serverKey,
            enableRelay: false,
            acceptConnections: true
        )
        defer { ffi.close(endpoint: server) }
        let routeJSON = try #require(ffi.routeJSON(server)?.data(using: .utf8))
        let route = try JSONDecoder().decode(CmxAttachRoute.self, from: routeJSON)
        let manager = CmxIrohEndpointManager(
            keyProvider: CmxIrohSecretKeyProvider(
                store: InMemoryIrohSecretStore(initialKey: clientKey),
                generate: { clientKey }
            ),
            ffiClient: ffi,
            enableRelay: false,
            acceptConnections: false
        )
        let transport = try CmxIrohByteTransport(
            route: route,
            endpointManager: manager,
            ffiClient: ffi,
            connectTimeoutNanoseconds: 5_000_000_000
        )
        let serverTask = Task.detached {
            let connection = try ffi.accept(endpoint: server, timeoutMilliseconds: 5_000)
            defer { ffi.close(connection: connection) }
            let received = try #require(try ffi.receive(connection: connection, maximumLength: 64))
            #expect(received == Data("ping".utf8))
            try ffi.send(connection: connection, data: Data("pong".utf8))
        }

        try await transport.connect()
        try await transport.send(Data("ping".utf8))
        let reply = try await transport.receive()
        await transport.close()
        try await serverTask.value

        #expect(reply == Data("pong".utf8))
    }

    private func peerRoute(endpointID: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(id: endpointID, relayHint: nil, directAddrs: [], relayURL: nil),
            priority: 0
        )
    }
}

private final class InMemoryIrohSecretStore: CmxIrohSecretKeyStoring, @unchecked Sendable {
    private var key: Data?

    init(initialKey: Data? = nil) {
        key = initialKey
    }

    func loadSecretKey() throws -> Data? {
        key
    }

    func saveSecretKey(_ key: Data) throws {
        self.key = key
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class FakeIrohFFIClient: CmxIrohFFIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [String] = []
    private var closedConnections = 0

    func generateSecretKey() throws -> Data {
        Data(repeating: 1, count: 32)
    }

    func bindEndpoint(
        secretKey: Data,
        enableRelay: Bool,
        acceptConnections: Bool
    ) throws -> CmxIrohEndpointReference {
        CmxIrohEndpointReference(raw: OpaquePointer(bitPattern: 0x1)!)
    }

    func endpointID(_ endpoint: CmxIrohEndpointReference) -> String? {
        "fake-phone"
    }

    func routeJSON(_ endpoint: CmxIrohEndpointReference) -> String? {
        nil
    }

    func online(endpoint: CmxIrohEndpointReference, timeoutMilliseconds: UInt64) throws {}

    func accept(
        endpoint: CmxIrohEndpointReference,
        timeoutMilliseconds: UInt64
    ) throws -> CmxIrohConnectionReference {
        CmxIrohConnectionReference(raw: OpaquePointer(bitPattern: 0x2)!)
    }

    func connect(
        endpoint: CmxIrohEndpointReference,
        peerID: String,
        relayURL: String?,
        directAddrs: [String],
        timeoutMilliseconds: UInt64
    ) throws -> CmxIrohConnectionReference {
        lock.lock()
        defer { lock.unlock() }
        peers.append(peerID)
        return CmxIrohConnectionReference(raw: OpaquePointer(bitPattern: 0x3)!)
    }

    func receive(connection: CmxIrohConnectionReference, maximumLength: Int) throws -> Data? {
        nil
    }

    func send(connection: CmxIrohConnectionReference, data: Data) throws {}

    func close(connection: CmxIrohConnectionReference) {
        lock.lock()
        defer { lock.unlock() }
        closedConnections += 1
    }

    func close(endpoint: CmxIrohEndpointReference) {}

    func connectedPeerIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return peers
    }

    func closedConnectionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return closedConnections
    }
}
