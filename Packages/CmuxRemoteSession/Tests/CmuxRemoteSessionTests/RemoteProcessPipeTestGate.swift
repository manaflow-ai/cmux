import Foundation

// Test-only process/pipe serialization. These suites deliberately close pipe
// read handles; a shared gate keeps Swift Testing's cross-suite parallelism from
// recycling those descriptors into a sibling process capture.
final class RemoteProcessPipeTestGate: @unchecked Sendable {
    static let shared = RemoteProcessPipeTestGate()

    private let lock = NSLock()

    private init() {}

    func run<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
