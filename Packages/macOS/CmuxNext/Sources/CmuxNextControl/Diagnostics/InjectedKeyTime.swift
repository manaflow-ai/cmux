#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextSettings
public import Foundation

/// The two times of a key `debug.key` injects (DEBUG and bench builds), both in seconds since boot
/// (`CLOCK_UPTIME_RAW`, `ProcessInfo.systemUptime`).
///
/// - `clientSent`: the request's `timestamp`, when the client sent the key (bench-typing.py,
///   sidebar-churn-typing.py). The event carries it, so the typing probe counts every wait before
///   the key is injected, as a real key's hardware time counts its wait in the event queue
///   (Chromium stamps the OS event's time, `ui::EventTimeStampFromSeconds`). That wait includes the
///   control socket's utility lane (threading-model.md) and the main-thread queue.
/// - `injected`: read on the main thread when the key is injected. The event carries it when the
///   request has no `timestamp`. The reply returns it (``report``), so a bench separates the
///   wait before injection from the app's own work after it.
///
/// ```swift
/// let time = InjectedKeyTime(params: call.params)            // on the main thread, at injection
/// let event = NSEvent.keyEvent(..., timestamp: time.eventTimestamp, ...)
/// reply.merge(time.report) { _, new in new }                 // injected_at, client_to_injection_ms
/// ```
public struct InjectedKeyTime: Sendable, Equatable {
    /// When the client sent the key (the request's `timestamp`), if it sent one.
    public let clientSent: TimeInterval?
    /// When the main thread injected the key.
    public let injected: TimeInterval

    /// The key's times, injected now. Call it on the main thread, when the key is injected.
    ///
    /// - Parameter params: The `debug.key` request's parameters (`timestamp` is optional).
    public init(params: [String: JSONValue]) {
        self.init(params: params, injectedAt: ProcessInfo.processInfo.systemUptime)
    }

    /// The key's times, injected at `injectedAt`.
    ///
    /// - Parameters:
    ///   - params: The `debug.key` request's parameters (`timestamp` is optional).
    ///   - injectedAt: When the main thread injected the key, in seconds since boot.
    public init(params: [String: JSONValue], injectedAt: TimeInterval) {
        clientSent = params["timestamp"]?.doubleValue
        injected = injectedAt
    }

    /// The key event's timestamp: the client's send time when it sent one, else the injection time.
    public var eventTimestamp: TimeInterval { clientSent ?? injected }

    /// The wait from the client's send to the injection (socket lane and main-thread queue), if the
    /// client sent a time.
    public var clientToInjection: TimeInterval? { clientSent.map { injected - $0 } }

    /// What the `debug.key` reply carries: `injected_at` (seconds since boot) and
    /// `client_to_injection_ms` (null without a client `timestamp`).
    public var report: [String: JSONValue] {
        ["injected_at": .number(injected),
         "client_to_injection_ms": clientToInjection.map { .number($0 * 1000) } ?? .null]
    }
}
#endif
