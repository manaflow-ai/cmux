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
