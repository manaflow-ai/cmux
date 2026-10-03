public import Foundation

/// What the helper runs for one request. Tests and dry runs replace it.
public protocol ServerFixRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String]) async throws -> FixRunResult
}

/// Runs the allowlisted executable with no shell and an empty environment.
public nonisolated struct ProcessFixRunner: ServerFixRunner {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String]) async throws -> FixRunResult {
        let pipe = Pipe()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = [:]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: FixRunResult(status: finished.terminationStatus, output: String(decoding: data.prefix(65_536), as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Records what would run (the prototype and tests never change a developer's Mac).
/// `customOutput` is what `pmset -g custom` returns.
public final nonisolated class DryRunFixRunner: ServerFixRunner, @unchecked Sendable {
    private let lock = NSLock() // concurrency-allow: guards one array append or copy, never held across an await or IO
    private var calls: [(URL, [String])] = []
    private let customOutput: String

    public init(customOutput: String = "") {
        self.customOutput = customOutput
    }

    public var recorded: [(URL, [String])] {
        lock.withLock { calls }
    }

    public func run(_ executable: URL, _ arguments: [String]) async throws -> FixRunResult {
        record(executable, arguments)
        return FixRunResult(status: 0, output: arguments == ["-g", "custom"] ? customOutput : "")
    }

    private func record(_ executable: URL, _ arguments: [String]) {
        lock.withLock { calls.append((executable, arguments)) }
    }
}
