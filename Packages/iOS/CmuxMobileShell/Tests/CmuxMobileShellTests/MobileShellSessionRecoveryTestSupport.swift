import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// Holds the live transport instance so tests can push unsolicited server-side
/// event frames and verify when recovery replaces the persistent connection.
final class TransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var transport: LivenessTransport?
    private var transportCreationCount = 0

    func set(_ transport: LivenessTransport) {
        lock.withLock {
            self.transport = transport
            transportCreationCount += 1
        }
    }

    func get() -> LivenessTransport? {
        lock.withLock { transport }
    }

    func createdTransportCount() -> Int {
        lock.withLock { transportCreationCount }
    }
}

struct LivenessTransportFactory: CmxByteTransportFactory {
    let router: LivenessHostRouter
    let box: TransportBox

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }
}
