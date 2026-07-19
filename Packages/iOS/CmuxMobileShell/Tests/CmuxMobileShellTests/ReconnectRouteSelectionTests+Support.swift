import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
@testable import CmuxMobileShell

@MainActor
extension ReconnectRouteSelectionTests {
    func makePairedMacStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        return (store, directory)
    }
}

final class SupersededTransportFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let router: LivenessHostRouter
    private let lock = NSLock()
    private var transports: [SupersededTrackingTransport] = []

    init(router: LivenessHostRouter) {
        self.router = router
    }

    func makeTransport(for _: CmxAttachRoute) throws -> any CmxByteTransport {
        let transport = SupersededTrackingTransport(router: router)
        lock.withLock { transports.append(transport) }
        return transport
    }

    func createdTransports() -> [SupersededTrackingTransport] {
        lock.withLock { transports }
    }
}

actor SupersededTrackingTransport: CmxByteTransport {
    private let base: LivenessTransport
    private var closeCount = 0

    init(router: LivenessHostRouter) {
        base = LivenessTransport(router: router)
    }

    func connect() async throws {
        try await base.connect()
    }

    func receive() async throws -> Data? {
        try await base.receive()
    }

    func send(_ data: Data) async throws {
        try await base.send(data)
    }

    func close() async {
        closeCount += 1
        await base.close()
    }

    func observedCloseCount() -> Int { closeCount }
}

final class KindRecordingTransportFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let router: LivenessHostRouter
    private let box: TransportBox
    private let failingKinds: Set<CmxAttachTransportKind>
    private let lock = NSLock()
    private var kinds: [CmxAttachTransportKind] = []

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
        lock.withLock { kinds.append(route.kind) }
        if failingKinds.contains(route.kind) {
            throw RouteRecordingTransportError.routeFailed
        }
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }

    func attemptedKinds() -> [CmxAttachTransportKind] {
        lock.withLock { kinds }
    }
}
