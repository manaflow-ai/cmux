import Foundation

final class CrashTestSequenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var values: [String] = []

    func append(_ value: String) {
        lock.withLock { values.append(value) }
        changed.signal()
    }

    var sequence: [String] {
        lock.withLock { values }
    }

    func removeAll() {
        lock.withLock { values.removeAll() }
    }

    func waitForCount(_ count: Int) {
        while sequence.count < count { changed.wait() }
    }
}
