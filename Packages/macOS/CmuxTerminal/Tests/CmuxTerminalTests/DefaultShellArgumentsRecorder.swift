import Foundation

final class DefaultShellArgumentsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var didResolveOnMainThread = false

    var invocationCount: Int {
        lock.withLock { count }
    }

    var resolvedOnMainThread: Bool {
        lock.withLock { didResolveOnMainThread }
    }

    func resolve() -> [String] {
        lock.withLock {
            count += 1
            didResolveOnMainThread = didResolveOnMainThread || Thread.isMainThread
        }
        return ["/usr/bin/login", "-flp", "tester"]
    }
}
