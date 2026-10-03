public import Foundation

/// What the helper runs for one request. Tests and dry runs replace it.
public protocol ServerFixRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String]) async throws -> FixRunResult
}

/// Runs the allowlisted executable with no shell and an empty environment,
/// killed after `limit` on the injected clock.
public nonisolated struct ProcessFixRunner: ServerFixRunner {
    private let limit: Duration
    private let clock: any Clock<Duration>

    public init(limit: Duration = .seconds(10), clock: any Clock<Duration> = ContinuousClock()) {
        self.limit = limit
        self.clock = clock
    }

    public func run(_ executable: URL, _ arguments: [String]) async throws -> FixRunResult {
        let child = FixChild(executable, arguments)
        return try await ServerHelperDeadline.run(limit: limit, clock: clock, operation: { try await child.start() }, onTimeout: { child.kill() })
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
