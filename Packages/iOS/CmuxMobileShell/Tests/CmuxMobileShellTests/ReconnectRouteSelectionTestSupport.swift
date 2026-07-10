import CMUXMobileCore
import Foundation
@testable import CmuxMobileShell

// Test support for ReconnectRouteSelectionTests: a transport factory that records
// each dial (host/port or iroh peer) and can fail or hold specific host/port routes.

private enum RouteRecordingTransportError: Error {
    case routeFailed
}

final class RouteRecordingTransportFactory: CmxByteTransportFactory, @unchecked Sendable {
    private let router: LivenessHostRouter
    private let box: TransportBox
    private let failingPorts: Set<Int>
    private let holdFirstFailingPort: Int?
    private let lock = NSLock()
    private var attempts: [String] = []
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
        // Record every dial (host/port or iroh peer). Host/port dials key on
        // their port so `failingPorts`/`holdFirstFailingPort` can target the
        // stale route; iroh peer dials never fail here (they are the good
        // fall-through route) and key on their endpoint id.
        let port: Int?
        let key: String
        switch route.endpoint {
        case let .hostPort(_, hostPort):
            port = hostPort
            key = String(hostPort)
        case let .peer(id, _, _, _):
            port = nil
            key = "iroh:\(id)"
        case .url:
            port = nil
            key = "url"
        }
        let shouldHold = lock.withLock {
            attempts.append(key)
            if let port, port == holdFirstFailingPort, !heldConnectConsumed {
                heldConnectConsumed = true
                return true
            }
            return false
        }
        if shouldHold {
            return HeldFailingConnectTransport(factory: self)
        }
        if let port, failingPorts.contains(port) {
            throw RouteRecordingTransportError.routeFailed
        }
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }

    func attemptedRoutes() -> [String] {
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
