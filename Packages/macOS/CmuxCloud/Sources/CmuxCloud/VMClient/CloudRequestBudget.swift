import CmuxFoundation
import Foundation

/// How long the caller of a control-plane request will wait for its answer.
///
/// A VM request can run under several deadlines at once: its `URLRequest`
/// timeout, the socket worker's per-method limit, the CLI's response timeout,
/// and the shared-read coordinator's budget. The earliest one decides when
/// the answer stops mattering. Each outer layer binds its deadline through a
/// budget, `VMClient` cuts the request's timeout to the earliest one, and the
/// request states that budget in ``headerField`` so the server answers inside
/// it (web/services/vms/routeDeadline.ts).
///
/// The deadline lives in task-local storage, so every budget value sees the
/// same bound deadline; a value only owns its clock.
public struct CloudRequestBudget: Sendable {
    /// Request header carrying the caller's budget in whole milliseconds.
    public static let headerField = "x-cmux-client-timeout-ms"

    /// Socket param a `vm.*` client sends with the time it still waits, in milliseconds.
    public static let socketParam = "cloud_client_timeout_ms"

    /// A `URLRequest` without an explicit timeout gives up after 60 seconds without a byte.
    public static let urlRequestDefaultTimeout: TimeInterval = 60

    /// The shortest timeout a request is given, so a spent budget still sends a well-formed request.
    public static let minimumTimeout: TimeInterval = 1

    /// The budget on the process's monotonic uptime clock.
    public static let live = CloudRequestBudget()

    // Bound by reference: a value payload can take macOS 14's back-deployed
    // TaskLocal fallback (see CloudReadRequestCoordinator).
    @TaskLocal private static var boundDeadline: TaskLocalReference<TimeInterval>?

    private let clock: @Sendable () -> TimeInterval

    /// Creates a budget reading deadlines on `clock` (seconds, monotonic).
    /// - Parameter clock: The clock deadlines are measured on; tests inject a fixed one.
    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// The current instant on this budget's clock.
    public func now() -> TimeInterval { clock() }

    /// The current task's deadline on this budget's clock, if a caller bound one.
    public var deadline: TimeInterval? { Self.boundDeadline?.value }

    /// Seconds left before the current task's deadline, or nil when none is bound.
    public func remainingSeconds() -> TimeInterval? {
        deadline.map { $0 - now() }
    }

    /// Runs `operation` with a deadline `seconds` from now. An enclosing
    /// earlier deadline still wins; `nil` keeps the enclosing one.
    public func withBudget<Result>(
        seconds: TimeInterval?,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        guard let bound = narrowedDeadline(seconds: seconds) else { return try await operation() }
        return try await Self.$boundDeadline.withReferencedValue(bound, isolation: isolation, operation: operation)
    }

    /// Synchronous ``withBudget(seconds:isolation:_:)`` for dispatchers that
    /// run before any task exists; tasks created inside inherit the deadline.
    public func withBudgetSync<Result>(seconds: TimeInterval?, _ operation: () throws -> Result) rethrows -> Result {
        guard let bound = narrowedDeadline(seconds: seconds) else { return try operation() }
        return try Self.$boundDeadline.withValue(TaskLocalReference(bound), operation: operation)
    }

    /// Runs `operation` with exactly a deadline `seconds` from now, replacing
    /// any enclosing one. A shared transport serves later waiters too, so it
    /// must not inherit the first caller's shorter deadline.
    public func withReplacedBudget<Result>(
        seconds: TimeInterval,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        try await Self.$boundDeadline.withReferencedValue(now() + max(0, seconds), isolation: isolation, operation: operation)
    }

    /// The timeout a request actually has: its own `URLRequest` timeout (60 s
    /// when unset), cut by the task's deadline, never below ``minimumTimeout``.
    public func effectiveTimeout(urlTimeout: TimeInterval?) -> TimeInterval {
        let own = urlTimeout ?? Self.urlRequestDefaultTimeout
        guard let remaining = remainingSeconds() else { return max(Self.minimumTimeout, own) }
        return max(Self.minimumTimeout, min(own, remaining))
    }

    /// The ``headerField`` value for a timeout: whole milliseconds, rounded down.
    public func headerValue(seconds: TimeInterval) -> String {
        String(Int(max(Self.minimumTimeout, seconds) * 1000))
    }

    /// Splits a `vm.*` socket call's params into the method's own params and
    /// the client's stated budget in seconds (``socketParam``), which is
    /// transport metadata no handler validates.
    public func socketClientBudget(from params: [String: Any]) -> (params: [String: Any], seconds: TimeInterval?) {
        guard let raw = params[Self.socketParam] else { return (params, nil) }
        var stripped = params
        stripped.removeValue(forKey: Self.socketParam)
        let milliseconds = (raw as? Int).map(Double.init) ?? (raw as? Double) ?? (raw as? NSNumber)?.doubleValue
        guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return (stripped, nil) }
        return (stripped, milliseconds / 1000)
    }

    private func narrowedDeadline(seconds: TimeInterval?) -> TimeInterval? {
        guard let seconds, seconds.isFinite else { return nil }
        let proposed = now() + max(0, seconds)
        return deadline.map { min($0, proposed) } ?? proposed
    }
}
