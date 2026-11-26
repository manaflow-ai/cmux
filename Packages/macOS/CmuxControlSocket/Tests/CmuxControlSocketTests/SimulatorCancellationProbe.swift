import Foundation

final class SimulatorCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    var isMarked: Bool {
        lock.withLock { marked }
    }

    func mark() {
        lock.withLock { marked = true }
    }
}
