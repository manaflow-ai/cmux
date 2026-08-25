import Foundation

final class ProcessIdentifierRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var processIdentifier: Int32?

    var value: Int32? { lock.withLock { processIdentifier } }

    func record(_ processIdentifier: Int32) {
        lock.withLock { self.processIdentifier = processIdentifier }
    }
}
