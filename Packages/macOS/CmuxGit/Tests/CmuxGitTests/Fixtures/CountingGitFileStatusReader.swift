import Foundation
@testable import CmuxGit

/// A status reader that delegates to the system reader while recording path
/// call counts and allowing deterministic status overrides.
final class CountingGitFileStatusReader: GitFileStatusReading, @unchecked Sendable {
    private let lock = NSLock()
    private let systemReader = SystemGitFileStatusReader()
    private var callsByPath: [String: Int] = [:]
    private var overridesByPath: [String: GitFileStatus] = [:]

    func status(atPath path: String) -> GitFileStatus? {
        lock.lock()
        callsByPath[path, default: 0] += 1
        let override = overridesByPath[path]
        lock.unlock()

        if let override {
            return override
        }
        return systemReader.status(atPath: path)
    }

    func callCount(atPath path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callsByPath[path] ?? 0
    }

    func statusWithoutRecording(atPath path: String) -> GitFileStatus? {
        systemReader.status(atPath: path)
    }

    func overrideStatus(_ status: GitFileStatus, atPath path: String) {
        lock.lock()
        overridesByPath[path] = status
        lock.unlock()
    }
}

/// A counting reader that can hold tracked-file status reads while concurrent
/// metadata requests reach the shared snapshot cache.
final class GatedCountingGitFileStatusReader: GitFileStatusReading, @unchecked Sendable {
    private let condition = NSCondition()
    private let systemReader = SystemGitFileStatusReader()
    private let gatedPath: String
    private var callsByPath: [String: Int] = [:]
    private var isGateOpen = false

    init(gatedPath: String) {
        self.gatedPath = gatedPath
    }

    func status(atPath path: String) -> GitFileStatus? {
        condition.lock()
        callsByPath[path, default: 0] += 1
        condition.broadcast()
        while path == gatedPath, !isGateOpen {
            condition.wait()
        }
        condition.unlock()
        return systemReader.status(atPath: path)
    }

    func callCount(atPath path: String) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return callsByPath[path] ?? 0
    }

    func waitForCallCount(
        atPath path: String,
        atLeast minimumCount: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while callsByPath[path, default: 0] < minimumCount {
            guard condition.wait(until: deadline) else {
                return callsByPath[path, default: 0] >= minimumCount
            }
        }
        return true
    }

    func openGate() {
        condition.lock()
        isGateOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Releases all concurrent test operations together after every caller has
/// arrived, making a cache-miss race deterministic.
actor ConcurrentOperationStartGate {
    private let expectedCount: Int
    private var arrivalCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func wait() async {
        arrivalCount += 1
        if arrivalCount == expectedCount {
            let readyWaiters = waiters
            waiters.removeAll()
            for waiter in readyWaiters {
                waiter.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
