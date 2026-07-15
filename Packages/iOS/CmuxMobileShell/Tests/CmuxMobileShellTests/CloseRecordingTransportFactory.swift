import CMUXMobileCore
import Foundation

final class CloseRecordingTransportFactory: CmxByteTransportFactory, @unchecked Sendable {
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
