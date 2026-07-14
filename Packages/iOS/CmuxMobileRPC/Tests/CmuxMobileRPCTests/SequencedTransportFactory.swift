import CMUXMobileCore
import Foundation

final class SequencedTransportFactory: @unchecked Sendable, CmxByteTransportFactory {
    private let lock = NSLock()
    private let transports: [any CmxByteTransport]
    private var nextIndex = 0

    init(_ transports: [any CmxByteTransport]) {
        precondition(!transports.isEmpty)
        self.transports = transports
    }

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        lock.withLock {
            let index = min(nextIndex, transports.count - 1)
            nextIndex += 1
            return transports[index]
        }
    }

    func createdTransportCount() -> Int {
        lock.withLock { nextIndex }
    }
}
