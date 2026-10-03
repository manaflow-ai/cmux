public import Foundation

/// What the helper runs for one request. Tests and dry runs replace it.
public protocol ServerFixRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String]) async throws -> Int32
}

/// Runs the allowlisted executable with no shell and an empty environment.
public nonisolated struct ProcessFixRunner: ServerFixRunner {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = [:]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Records what would run (the prototype and tests never change a developer's Mac).
public final nonisolated class DryRunFixRunner: ServerFixRunner, @unchecked Sendable {
    private let lock = NSLock() // concurrency-allow: guards one array append or copy, never held across an await or IO
    private var calls: [(URL, [String])] = []

    public init() {}

    public var recorded: [(URL, [String])] {
        lock.withLock { calls }
    }

    public func run(_ executable: URL, _ arguments: [String]) async throws -> Int32 {
        record(executable, arguments)
        return 0
    }

    private func record(_ executable: URL, _ arguments: [String]) {
        lock.withLock { calls.append((executable, arguments)) }
    }
}
