import CMUXMobileCore
import CmuxMobileTransport
import Foundation

// The lock synchronously coordinates test transport creation and one-shot continuation handoff.
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
