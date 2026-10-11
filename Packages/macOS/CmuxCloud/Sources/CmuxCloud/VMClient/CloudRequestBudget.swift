import CmuxFoundation
import Foundation

/// How long the caller of a control-plane request will wait for its answer.
///
/// A VM request can run under several deadlines at once: its `URLRequest`
/// timeout, the socket worker's per-method limit, the CLI's response timeout,
/// and the shared-read coordinator's budget. The earliest one decides when
/// the answer stops mattering. Each outer layer binds its deadline here,
/// `VMClient` cuts the request's timeout to the earliest one, and the request
/// states that budget in ``headerField`` so the server answers inside it
/// (web/services/vms/routeDeadline.ts).
public enum CloudRequestBudget {
    /// Request header carrying the caller's budget in whole milliseconds.
    public static let headerField = "x-cmux-client-timeout-ms"

    /// A `URLRequest` without an explicit timeout gives up after 60 seconds without a byte.
    public static let urlRequestDefaultTimeout: TimeInterval = 60

    /// The shortest timeout a request is given, so a spent budget still sends a well-formed request.
    static let minimumTimeout: TimeInterval = 1

    // Bound by reference: a value payload can take macOS 14's back-deployed
    // TaskLocal fallback (see CloudReadRequestCoordinator).
    @TaskLocal private static var boundDeadline: TaskLocalReference<TimeInterval>?

    /// The current task's deadline as `ProcessInfo.systemUptime` seconds, if a caller bound one.
    public static var deadline: TimeInterval? { boundDeadline?.value }

    /// The monotonic clock deadlines are measured on.
    public static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Runs `operation` with a deadline `seconds` from now. An enclosing
    /// earlier deadline still wins; `nil` keeps the enclosing one.
    public static func withBudget<Result>(
        seconds: TimeInterval?,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        guard let seconds, seconds.isFinite else { return try await operation() }
        let proposed = now() + max(0, seconds)
        let bound = deadline.map { min($0, proposed) } ?? proposed
        return try await $boundDeadline.withReferencedValue(bound, isolation: isolation, operation: operation)
    }

    /// Synchronous ``withBudget(seconds:isolation:_:)`` for dispatchers that
    /// run before any task exists; tasks created inside inherit the deadline.
    public static func withBudgetSync<Result>(seconds: TimeInterval?, _ operation: () throws -> Result) rethrows -> Result {
        guard let seconds, seconds.isFinite else { return try operation() }
        let proposed = now() + max(0, seconds)
        let bound = deadline.map { min($0, proposed) } ?? proposed
        return try $boundDeadline.withValue(TaskLocalReference(bound), operation: operation)
    }

    /// Runs `operation` with exactly a deadline `seconds` from now, replacing
    /// any enclosing one. A shared transport serves later waiters too, so it
    /// must not inherit the first caller's shorter deadline.
    public static func withReplacedBudget<Result>(
        seconds: TimeInterval,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $boundDeadline.withReferencedValue(now() + max(0, seconds), isolation: isolation, operation: operation)
    }

    /// Socket param a `vm.*` client sends with the time it still waits, in milliseconds.
    public static let socketParam = "cloud_client_timeout_ms"

    /// Splits a `vm.*` socket call's params into the method's own params and
    /// the client's stated budget in seconds (``socketParam``), which is
    /// transport metadata no handler validates.
    public static func socketClientBudget(from params: [String: Any]) -> (params: [String: Any], seconds: TimeInterval?) {
        guard let raw = params[socketParam] else { return (params, nil) }
        var stripped = params
        stripped.removeValue(forKey: socketParam)
        let milliseconds = (raw as? Int).map(Double.init) ?? (raw as? Double) ?? (raw as? NSNumber)?.doubleValue
        guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return (stripped, nil) }
        return (stripped, milliseconds / 1000)
    }

    /// The timeout a request actually has: its own `URLRequest` timeout (60 s
    /// when unset), cut by the task's deadline, never below ``minimumTimeout``.
    public static func effectiveTimeout(
        urlTimeout: TimeInterval?,
        deadline: TimeInterval?,
        now: TimeInterval
    ) -> TimeInterval {
        let own = urlTimeout ?? urlRequestDefaultTimeout
        guard let deadline else { return max(minimumTimeout, own) }
        return max(minimumTimeout, min(own, deadline - now))
    }

    /// The ``headerField`` value for a timeout: whole milliseconds, rounded down.
    public static func headerValue(seconds: TimeInterval) -> String {
        String(Int(max(minimumTimeout, seconds) * 1000))
    }
}
