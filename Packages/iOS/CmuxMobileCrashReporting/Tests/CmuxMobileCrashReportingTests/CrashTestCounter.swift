import Foundation

final class CrashTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var storedValue = 0

    var value: Int {
        lock.withLock { storedValue }
    }

    func increment() {
        lock.withLock { storedValue += 1 }
        changed.signal()
    }

    func waitForValue(_ target: Int) {
        while value < target { changed.wait() }
    }
}
