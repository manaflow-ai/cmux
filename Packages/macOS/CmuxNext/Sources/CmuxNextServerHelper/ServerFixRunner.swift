public import Foundation

/// What the helper runs for one request. Tests and dry runs replace it.
public protocol ServerFixRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String]) async throws -> FixRunResult
}

/// Runs the allowlisted executable with no shell and an empty environment,
/// killed after `limit` on the injected clock, at most `tolerance` late.
public nonisolated struct ProcessFixRunner: ServerFixRunner {
    /// How long the helper lets one fix run (`pmset` answers in well under a second).
    public static let helperLimit: Duration = .seconds(10)
    /// WakeLeeway's tolerance for ``helperLimit``: the helper links no CmuxNextWakeups,
    /// and ServerHelperLeewayTests checks that the two stay equal.
    public static let helperTolerance: Duration = .seconds(1)

    private let limit: Duration
    private let tolerance: Duration
    private let clock: any Clock<Duration>

    /// The helper's runner: ``helperLimit``, ``helperTolerance``.
    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.init(limit: Self.helperLimit, tolerance: Self.helperTolerance, clock: clock)
    }

    /// A runner that kills its child `limit` after the start, at most `tolerance` late.
    public init(limit: Duration, tolerance: Duration, clock: any Clock<Duration> = ContinuousClock()) {
        self.limit = limit
        self.tolerance = tolerance
        self.clock = clock
    }

    public func run(_ executable: URL, _ arguments: [String]) async throws -> FixRunResult {
        let child = FixChild(executable, arguments)
        return try await ServerHelperDeadline().run(limit: limit, tolerance: tolerance, clock: clock,
                                                    operation: { try await child.start() }, onTimeout: { child.kill() })
    }
}
