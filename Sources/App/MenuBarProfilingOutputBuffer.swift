import Foundation

final class MenuBarProfilingOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func append(_ text: String) {
        lock.lock()
        value += text
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = ""
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        let current = value
        lock.unlock()
        return current
    }
}
