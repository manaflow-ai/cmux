import CMUXMobileCore
import Foundation

enum SequencedTransportFactoryError: Error, Equatable {
    case exhausted
}

final class SequencedTransportFactory: @unchecked Sendable, CmxByteTransportFactory {
    private let lock = NSLock()
    private let transports: [any CmxByteTransport]
    private var nextIndex = 0

    init(_ transports: [any CmxByteTransport]) {
        precondition(!transports.isEmpty)
        self.transports = transports
    }

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        try lock.withLock {
            guard nextIndex < transports.count else {
                throw SequencedTransportFactoryError.exhausted
            }
            let transport = transports[nextIndex]
            nextIndex += 1
            return transport
        }
    }

    func createdTransportCount() -> Int {
        lock.withLock { nextIndex }
    }
}
