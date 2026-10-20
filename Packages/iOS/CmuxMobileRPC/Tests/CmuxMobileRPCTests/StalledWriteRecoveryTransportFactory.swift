import CMUXMobileCore
import Foundation

final class StalledWriteRecoveryTransportFactory: @unchecked Sendable, CmxByteTransportFactory {
    // Test-only synchronous factory conformance; the lock protects only the creation count.
    private let lock = NSLock()
    private let stalled: StalledWriteTransport
    private let recovery: ResponseTimeoutSurvivalTransport
    private var creationCount = 0

    init(
        stalled: StalledWriteTransport,
        recovery: ResponseTimeoutSurvivalTransport
    ) {
        self.stalled = stalled
        self.recovery = recovery
    }

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        lock.withLock {
            creationCount += 1
            return creationCount == 1 ? stalled : recovery
        }
    }

    func createdTransportCount() -> Int {
        lock.withLock { creationCount }
    }
}
