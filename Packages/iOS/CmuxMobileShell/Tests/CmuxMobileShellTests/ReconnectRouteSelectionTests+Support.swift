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

enum RouteRecordingTransportError: Error {
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

actor HeldFailingConnectTransport: CmxByteTransport {
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

final class KindRecordingTransportFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let router: LivenessHostRouter
    private let box: TransportBox
    private let failingKinds: Set<CmxAttachTransportKind>
    private let lock = NSLock()
    private var kinds: [CmxAttachTransportKind] = []
    private var authorizationModes: [CmxTransportAuthorizationMode] = []

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
        return try makeRecordedTransport(for: route)
    }

    func makeTransport(
        for request: CmxByteTransportRequest
    ) throws -> any CmxByteTransport {
        lock.withLock {
            kinds.append(request.route.kind)
            authorizationModes.append(request.authorizationMode)
        }
        return try makeRecordedTransport(for: request.route)
    }

    private func makeRecordedTransport(
        for route: CmxAttachRoute
    ) throws -> any CmxByteTransport {
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

    func attemptedAuthorizationModes() -> [CmxTransportAuthorizationMode] {
        lock.withLock { authorizationModes }
    }
}
