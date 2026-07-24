import Foundation

// The lock serializes every mutation and snapshot of the backing array.
final class LockedTextInputCompletions: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    func append(_ value: Bool) { lock.withLock { storage.append(value) } }
    func values() -> [Bool] { lock.withLock { storage } }
}
