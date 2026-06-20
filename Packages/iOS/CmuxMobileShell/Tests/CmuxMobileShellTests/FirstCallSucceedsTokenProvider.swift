import Foundation

/// Uses a private lock to guard the one-shot counter for concurrent test token requests.
final class FirstCallSucceedsTokenProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() throws -> String {
        let n: Int = lock.withLock {
            count += 1
            return count
        }
        guard n == 1 else { throw TestStackTokenError() }
        return "token-1"
    }
}
