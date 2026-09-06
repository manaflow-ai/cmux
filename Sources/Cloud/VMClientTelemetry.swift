import Foundation
import os

/// W3C trace context the client mints for one Cloud VM API request.
///
/// The server keeps the trace id when it can (its sampler still makes its own
/// sampling decision) and always answers with `x-cmux-trace-id`, so a failure
/// seen on the Mac and the span stored in Axiom share a key even when the
/// response never arrived.
struct VMRequestTraceContext: Sendable, Equatable {
    /// 32 lowercase hex characters, never all zero.
    let traceId: String
    /// 16 lowercase hex characters, never all zero.
    let spanId: String
    /// Stable id for the logical request across 429 retries.
    let clientRequestId: String

    static let traceparentHeader = "traceparent"
    static let clientRequestIdHeader = "X-Cmux-Client-Request-Id"
    static let serverTraceIdHeader = "x-cmux-trace-id"

    /// `00-<trace id>-<span id>-01`; sampled flag set so intermediaries keep it.
    var traceparent: String { "00-\(traceId)-\(spanId)-01" }

    var headers: [String: String] {
        [
            Self.traceparentHeader: traceparent,
            Self.clientRequestIdHeader: clientRequestId,
        ]
    }

    static func mint() -> VMRequestTraceContext {
        VMRequestTraceContext(
            traceId: randomHex(bytes: 16),
            spanId: randomHex(bytes: 8),
            clientRequestId: UUID().uuidString.lowercased()
        )
    }

    private static func randomHex(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        repeat {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max)
            }
        } while bytes.allSatisfy { $0 == 0 }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// How one Cloud VM API request ended, as seen by the client.
enum VMRequestOutcome: Sendable, Equatable {
    /// The server answered. `errorCode` is its machine-readable `error` for a
    /// 4xx/5xx body, `nil` on success.
    case response(status: Int, errorCode: String?, serverTraceId: String?)
    /// No HTTP response: DNS, connect, TLS, timeout, or a local precondition.
    case transportFailure(kind: VMTransportFailureKind, detail: String)

    var isSuccess: Bool {
        if case .response(let status, _, _) = self { return status < 400 }
        return false
    }

    var httpStatus: Int? {
        if case .response(let status, _, _) = self { return status }
        return nil
    }

    /// One token that names the failure class for grouping.
    var errorCode: String? {
        switch self {
        case .response(let status, let errorCode, _):
            if status < 400 { return nil }
            return errorCode ?? "http_\(status)"
        case .transportFailure(let kind, _):
            return kind.rawValue
        }
    }

    var serverTraceId: String? {
        if case .response(_, _, let traceId) = self { return traceId }
        return nil
    }
}

enum VMTransportFailureKind: String, Sendable {
    case notSignedIn = "not_signed_in"
    case sessionRefreshFailed = "session_refresh_failed"
    case backendUnreachable = "backend_unreachable"
    case malformedResponse = "malformed_response"
    case cancelled = "cancelled"
    case urlError = "url_error"
    case unknown = "unknown"
}

/// One measured Cloud VM API request.
struct VMRequestTelemetryRecord: Sendable, Equatable {
    let method: String
    /// Request path with machine ids replaced by `{id}` (`/api/vm/{id}/exec`).
    let route: String
    let outcome: VMRequestOutcome
    let durationMs: Double
    let retryCount: Int
    let trace: VMRequestTraceContext

    /// `"POST /api/vm"`; the same shape the server's `cmux.api.*` span names use.
    var operation: String { "\(method) \(route)" }

    /// The id operators look up: the server's when it answered, else ours.
    var referenceTraceId: String { outcome.serverTraceId ?? trace.traceId }
}

enum VMRequestFailureSeverity: String, Sendable {
    case error
    case warning
}

/// Client-side telemetry for the Cloud VM control plane. Sinks:
///
/// - `os.log` (subsystem `com.cmuxterm.app`, category `CloudVM`) for every
///   request, readable from release builds with `log show`;
/// - a Sentry breadcrumb for every request and a Sentry event for failures
///   (5xx and transport failures are `error`, 4xx are `warning`);
/// - PostHog `cmux_cloud_vm_request` for every failure and for the successes a
///   user waits on (create, attach, base open, ...), with the duration.
///
/// Failures are throttled per operation and error code so a polling loop
/// during an outage yields one event per window instead of hundreds. Every
/// event carries the trace id and client request id.
final class VMClientTelemetry: @unchecked Sendable {
    static let shared = VMClientTelemetry()

    static let postHogEvent = "cmux_cloud_vm_request"
    static let sentryCategory = "cloud_vm"
    static let postHogFailureThrottle: TimeInterval = 60
    static let sentryFailureThrottle: TimeInterval = 300

    typealias Capture = @Sendable (String, [String: Any]) -> Void
    typealias SentryCapture = @Sendable (String, VMRequestFailureSeverity, [String: Any]) -> Void
    typealias Breadcrumb = @Sendable (String, [String: Any]) -> Void

    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "CloudVM")
    private let capturePostHog: Capture
    private let captureSentry: SentryCapture
    private let addBreadcrumb: Breadcrumb
    private let now: @Sendable () -> Date
    private let channel: String
    private let lock = NSLock()
    private var lastPostHogFailure: [String: Date] = [:]
    private var lastSentryFailure: [String: Date] = [:]

    init(
        capturePostHog: @escaping Capture = { event, properties in
            PostHogAnalytics.shared.capture(event, properties: properties)
        },
        captureSentry: @escaping SentryCapture = { message, severity, data in
            switch severity {
            case .error:
                sentryCaptureError(message, category: VMClientTelemetry.sentryCategory, data: data)
            case .warning:
                sentryCaptureWarning(message, category: VMClientTelemetry.sentryCategory, data: data)
            }
        },
        addBreadcrumb: @escaping Breadcrumb = { message, data in
            sentryBreadcrumb(message, category: VMClientTelemetry.sentryCategory, data: data)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        channel: String = BuildFlavor.current.rawValue
    ) {
        self.capturePostHog = capturePostHog
        self.captureSentry = captureSentry
        self.addBreadcrumb = addBreadcrumb
        self.now = now
        self.channel = channel
    }

    /// Identity headers sent with every request so server spans and events can
    /// be broken down by client, version, build and channel.
    static func clientIdentityHeaders(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        channel: String = BuildFlavor.current.rawValue
    ) -> [String: String] {
        var headers = ["X-Cmux-Client": "cmux-mac", "X-Cmux-Channel": channel]
        if let version = infoDictionary["CFBundleShortVersionString"] as? String, !version.isEmpty {
            headers["X-Cmux-App-Version"] = version
        }
        if let build = infoDictionary["CFBundleVersion"] as? String, !build.isEmpty {
            headers["X-Cmux-App-Build"] = build
        }
        return headers
    }

    func record(_ record: VMRequestTelemetryRecord) {
        log(record)
        addBreadcrumb(
            "\(record.operation) \(record.outcome.isSuccess ? "ok" : "failed")",
            Self.breadcrumbData(record)
        )
        if Self.shouldCaptureToPostHog(record), allow(record, in: &lastPostHogFailure, window: Self.postHogFailureThrottle) {
            capturePostHog(Self.postHogEvent, Self.postHogProperties(record, channel: channel))
        }
        if let severity = Self.sentrySeverity(record),
           allow(record, in: &lastSentryFailure, window: Self.sentryFailureThrottle) {
            captureSentry(
                "cloud VM \(record.operation) failed: \(record.outcome.errorCode ?? "unknown")",
                severity,
                Self.sentryData(record)
            )
        }
    }

    // MARK: - Decisions (pure, tested)

    /// Reads a client polls on a timer. Their successes stay out of PostHog.
    static func isPolledOperation(method: String, route: String) -> Bool {
        guard method.uppercased() == "GET" else { return false }
        switch route {
        case "/api/vm", "/api/vm/{id}", "/api/vm/{id}/stats", "/api/vm/{id}/sessions", "/api/vm/tunnel":
            return true
        default:
            return false
        }
    }

    /// `/api/vm/<machine id>/exec` -> `/api/vm/{id}/exec`. Machine ids are the
    /// segment after `/api/vm/` unless it is a fixed sub-resource.
    static func normalizedRoute(path: String) -> String {
        let fixed: Set<String> = ["base", "leases", "restore", "tunnel"]
        var segments = path.split(separator: "?", maxSplits: 1)[0].split(separator: "/").map(String.init)
        if segments.count >= 3, segments[0] == "api", segments[1] == "vm", !fixed.contains(segments[2]) {
            segments[2] = "{id}"
        }
        return "/" + segments.joined(separator: "/")
    }

    static func shouldCaptureToPostHog(_ record: VMRequestTelemetryRecord) -> Bool {
        if !record.outcome.isSuccess { return true }
        return !isPolledOperation(method: record.method, route: record.route)
    }

    /// Server faults and transport failures are errors. Client-side
    /// preconditions (not signed in, cancelled) are not incidents. 4xx are the
    /// caller's fault and stay visible as warnings.
    static func sentrySeverity(_ record: VMRequestTelemetryRecord) -> VMRequestFailureSeverity? {
        switch record.outcome {
        case .response(let status, _, _):
            if status < 400 { return nil }
            return status >= 500 ? .error : .warning
        case .transportFailure(let kind, _):
            switch kind {
            case .notSignedIn, .sessionRefreshFailed, .cancelled:
                return nil
            case .backendUnreachable, .malformedResponse, .urlError, .unknown:
                return .error
            }
        }
    }

    static func throttleKey(_ record: VMRequestTelemetryRecord) -> String {
        "\(record.operation)|\(record.outcome.errorCode ?? "ok")"
    }

    static func postHogProperties(_ record: VMRequestTelemetryRecord, channel: String) -> [String: Any] {
        var properties: [String: Any] = [
            "operation": record.operation,
            "method": record.method,
            "route": record.route,
            "success": record.outcome.isSuccess,
            "duration_ms": (record.durationMs * 100).rounded() / 100,
            "retry_count": record.retryCount,
            "trace_id": record.referenceTraceId,
            "client_trace_id": record.trace.traceId,
            "client_request_id": record.trace.clientRequestId,
            "channel": channel,
            "schema_version": 1,
        ]
        if let status = record.outcome.httpStatus {
            properties["status"] = status
        }
        if let errorCode = record.outcome.errorCode {
            properties["error_code"] = errorCode
            properties["operator_fault"] = sentrySeverity(record) == .error
        }
        if case .transportFailure(let kind, _) = record.outcome {
            properties["transport_failure"] = kind.rawValue
        }
        return properties
    }

    static func sentryData(_ record: VMRequestTelemetryRecord) -> [String: Any] {
        var data = postHogProperties(record, channel: "")
        data.removeValue(forKey: "channel")
        data.removeValue(forKey: "schema_version")
        if case .transportFailure(_, let detail) = record.outcome {
            data["detail"] = String(detail.prefix(300))
        }
        return data
    }

    static func breadcrumbData(_ record: VMRequestTelemetryRecord) -> [String: Any] {
        var data: [String: Any] = [
            "duration_ms": (record.durationMs * 100).rounded() / 100,
            "trace_id": record.referenceTraceId,
            "client_request_id": record.trace.clientRequestId,
        ]
        if let status = record.outcome.httpStatus { data["status"] = status }
        if let errorCode = record.outcome.errorCode { data["error_code"] = errorCode }
        return data
    }

    // MARK: - Private

    private func log(_ record: VMRequestTelemetryRecord) {
        let duration = Int(record.durationMs.rounded())
        switch record.outcome {
        case .response(let status, let errorCode, _):
            if status < 400 {
                logger.info("\(record.operation, privacy: .public) \(status) \(duration)ms trace=\(record.referenceTraceId, privacy: .public) req=\(record.trace.clientRequestId, privacy: .public)")
            } else {
                logger.error("\(record.operation, privacy: .public) \(status) \(errorCode ?? "-", privacy: .public) \(duration)ms trace=\(record.referenceTraceId, privacy: .public) req=\(record.trace.clientRequestId, privacy: .public)")
            }
        case .transportFailure(let kind, let detail):
            logger.error("\(record.operation, privacy: .public) \(kind.rawValue, privacy: .public) \(duration)ms trace=\(record.trace.traceId, privacy: .public) req=\(record.trace.clientRequestId, privacy: .public) detail=\(detail, privacy: .public)")
        }
    }

    /// Successes always pass; failures pass once per key per window.
    private func allow(_ record: VMRequestTelemetryRecord, in table: inout [String: Date], window: TimeInterval) -> Bool {
        guard !record.outcome.isSuccess else { return true }
        let key = Self.throttleKey(record)
        let current = now()
        lock.lock()
        defer { lock.unlock() }
        if let last = table[key], current.timeIntervalSince(last) < window {
            return false
        }
        table[key] = current
        return true
    }
}
