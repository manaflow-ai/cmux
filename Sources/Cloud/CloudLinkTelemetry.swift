import Foundation
import OSLog
import CryptoKit

/// Production diagnostics for the sidebar's cloud machine links. This path previously
/// had no non-DEBUG signal at all: `cmuxDebugLog` compiles out of release builds,
/// app-side PostHog only counted active users, and the control plane's Axiom spans end
/// at the attach-endpoint response — so a machine stuck on "Connecting…" in a nightly
/// or stable build was undiagnosable in the field.
///
/// Two sinks:
/// - os.log (subsystem `com.cmuxterm.app`, category `CloudLink`): every lifecycle
///   transition, readable from release builds via Console or
///   `log show --predicate 'subsystem == "com.cmuxterm.app" AND category == "CloudLink"'`.
///   Only bounded enum values and a per-launch keyed machine identifier are public.
///   Raw routes, socket paths, provider output, and error descriptions never enter a
///   log record.
/// - PostHog event `cmux_cloud_link_error`: failures only, matching the server's
///   `cloud_vm_provision` errors-only split, throttled per machine+stage so the 45 s
///   sidebar refresh loop cannot flood the project while a machine stays broken.
enum CloudLinkTelemetry {
    static let logger = Logger(subsystem: "com.cmuxterm.app", category: "CloudLink")

    static let eventName = "cmux_cloud_link_error"

    /// One capture per machine+stage per interval; os.log still records every occurrence.
    private static let captureThrottle = CloudLinkCaptureThrottle(interval: 5 * 60)
    /// A fresh key on every launch prevents the analytics event from becoming a stable
    /// cross-install machine identifier while still grouping one machine's failures
    /// during the current launch.
    private static let correlationSalt = Data(UUID().uuidString.utf8)

    // MARK: - Lifecycle logs

    static func connectStarted(machineID: String) {
        logger.info("connect start machine=\(machineCorrelationID(machineID), privacy: .public)")
    }

    static func attachEndpointResolved(machineID: String, durationMs: Int) {
        logger.info("attach-endpoint resolved machine=\(machineCorrelationID(machineID), privacy: .public) duration_ms=\(boundedDuration(durationMs), privacy: .public)")
    }

    static func connected(machineID: String, socketPath: String, durationMs: Int) {
        // `socketPath` is intentionally ignored. It contains a local filesystem path
        // and can include account names or other private state.
        logger.info("connected machine=\(machineCorrelationID(machineID), privacy: .public) duration_ms=\(boundedDuration(durationMs), privacy: .public)")
    }

    static func connectFailed(machineID: String, error: Error, durationMs: Int) {
        let stage = Self.stage(for: error)
        let errorClass = Self.errorClass(for: error)
        logger.error("connect failed machine=\(machineCorrelationID(machineID), privacy: .public) stage=\(stage, privacy: .public) class=\(errorClass, privacy: .public) duration_ms=\(boundedDuration(durationMs), privacy: .public)")
        // A backoff rejection re-reports the failure that armed it; capturing it again
        // would double-count one incident.
        guard stage != "retry_backoff" else { return }
        capture(machineID: machineID, stage: stage, error: error, extra: ["duration_ms": durationMs])
    }

    static func linkExited(machineID: String, status: Int32, wasConnected: Bool, stderrTail: String) {
        // The child controls stderr. A token regex cannot reliably distinguish a
        // secret from a path, prompt, or future credential format, so the tail is
        // deliberately discarded at this boundary.
        _ = stderrTail
        logger.error("link exited machine=\(machineCorrelationID(machineID), privacy: .public) status=\(boundedExitStatus(status), privacy: .public) was_connected=\(wasConnected, privacy: .public)")
        guard status != 0 else { return }
        capture(
            machineID: machineID,
            stage: "link_exit",
            errorClass: "exited",
            extra: ["exit_status": Int(boundedExitStatus(status)), "was_connected": wasConnected]
        )
    }

    /// The registry's machine-list read failed, so no provider refreshes ran this cycle.
    /// This was a silent `try?` before: under a sustained failure (rate limiting, auth,
    /// backend outage) the whole cloud tree froze in its last state with no trace.
    static func machineListFailed(error: Error) {
        logger.error("machine list refresh failed class=\(errorClass(for: error), privacy: .public)")
        capture(machineID: "all", stage: "list_machines", error: error)
    }

    static func providerRefreshFailed(machineID: String, state: SurfaceLinkState, error: Error) {
        logger.error("provider refresh failed machine=\(machineCorrelationID(machineID), privacy: .public) link_state=\(state.rawValue, privacy: .public) class=\(errorClass(for: error), privacy: .public)")
        // `connecting` here means another attempt is already in flight and will report
        // its own outcome; only a settled error state is a new incident.
        guard state == .error else { return }
        capture(machineID: machineID, stage: "provider_refresh", error: error, extra: ["link_state": state.rawValue])
    }

    static func linkStateChanged(machineID: String, from: SurfaceLinkState, to: SurfaceLinkState) {
        guard from != to else { return }
        logger.info("link state machine=\(machineCorrelationID(machineID), privacy: .public) \(from.rawValue, privacy: .public) -> \(to.rawValue, privacy: .public)")
    }

    // MARK: - Classification

    /// Which step of the connect pipeline an error came from, derived from its type so
    /// the pipeline code does not thread a stage variable through every await.
    static func stage(for error: Error) -> String {
        switch error {
        case is VMClientError:
            return "attach_endpoint"
        case CloudMachineLink.LinkError.spawnFailed:
            return "spawn"
        case CloudMachineLink.LinkError.timedOut:
            return "socket_wait"
        case CloudMachineLink.LinkError.exited:
            return "link_exit"
        case CloudMachineLink.LinkError.clientMissing,
             CloudMachineLinkManager.ManagerError.clientMissing:
            return "client_missing"
        case CloudMachineLinkManager.ManagerError.retryLater:
            return "retry_backoff"
        default:
            return "other"
        }
    }

    /// A short grouping key for PostHog insights, coarser than the error text.
    static func errorClass(for error: Error) -> String {
        switch error {
        case VMClientError.notSignedIn:
            return "not_signed_in"
        case VMClientError.sessionRefreshFailed:
            return "session_refresh_failed"
        case VMClientError.backendUnreachable:
            return "backend_unreachable"
        case VMClientError.httpStatus(let code, _):
            return "http_\(code)"
        case VMClientError.malformedResponse:
            return "malformed_response"
        case CloudMachineLink.LinkError.spawnFailed:
            return "spawn_failed"
        case CloudMachineLink.LinkError.timedOut:
            return "timeout"
        case CloudMachineLink.LinkError.exited:
            return "exited"
        case CloudMachineLink.LinkError.clientMissing,
             CloudMachineLinkManager.ManagerError.clientMissing:
            return "client_missing"
        case CloudMachineLinkManager.ManagerError.retryLater:
            return "retry_backoff"
        case is CancellationError:
            return "cancelled"
        default:
            return "other"
        }
    }

    /// Legacy helper for callers that need to display a route in a local diagnostic.
    /// Telemetry does not call it because arbitrary non-token data is still sensitive.
    static func redactSecrets(_ text: String) -> String {
        let redacted = text.replacingOccurrences(
            of: #"([?&][A-Za-z0-9_-]*token[A-Za-z0-9_-]*=)[^&\s"'\\]+"#,
            with: "$1REDACTED",
            options: [.regularExpression, .caseInsensitive]
        )
        return String(redacted.unicodeScalars.filter { !$0.properties.isControl }.prefix(512))
    }

    // MARK: - Capture

    private static func capture(
        machineID: String,
        stage: String,
        error: Error,
        extra: [String: Any] = [:]
    ) {
        capture(
            machineID: machineID,
            stage: stage,
            errorClass: errorClass(for: error),
            extra: extra
        )
    }

    private static func capture(
        machineID: String,
        stage: String,
        errorClass: String,
        extra: [String: Any]
    ) {
        guard captureThrottle.shouldSend(key: "\(machineID)|\(stage)") else { return }
        var properties: [String: Any] = [
            "machine_id": machineCorrelationID(machineID),
            "stage": stage,
            "error_class": errorClass,
            "schema_version": 2,
        ]
        for (key, value) in extra {
            switch key {
            case "duration_ms":
                if let number = value as? Int { properties[key] = boundedDuration(number) }
            case "exit_status":
                if let number = value as? Int {
                    properties[key] = Int(boundedExitStatus(Int32(number)))
                }
            case "was_connected":
                if let flag = value as? Bool { properties[key] = flag }
            case "link_state":
                if let state = value as? String, Self.allowedLinkStates.contains(state) { properties[key] = state }
            default:
                break
            }
        }
        PostHogAnalytics.shared.captureDiagnostic(event: eventName, properties: properties)
    }

    private static let allowedLinkStates: Set<String> = [
        SurfaceLinkState.connecting.rawValue,
        SurfaceLinkState.connected.rawValue,
        SurfaceLinkState.error.rawValue,
        SurfaceLinkState.unavailable.rawValue,
        SurfaceLinkState.asleep.rawValue,
    ]

    /// A short, non-reversible correlation value for this process. A plain SHA-256
    /// would let anyone with a machine-ID dictionary reverse the identifier, so the
    /// per-launch salt is part of the digest input.
    static func machineCorrelationID(_ machineID: String) -> String {
        let digest = SHA256.hash(data: correlationSalt + Data(machineID.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private static func boundedDuration(_ value: Int) -> Int {
        min(max(value, 0), 24 * 60 * 60 * 1_000)
    }

    private static func boundedExitStatus(_ value: Int32) -> Int32 {
        min(max(value, -1), 255)
    }
}

/// Allows one send per key per interval. Lock-guarded because failures surface from
/// actors, detached tasks, and the main actor alike.
final class CloudLinkCaptureThrottle: @unchecked Sendable {
    private let interval: TimeInterval
    private let lock = NSLock()
    private var lastSent: [String: Date] = [:]

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func shouldSend(key: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastSent[key], now.timeIntervalSince(last) < interval {
            return false
        }
        lastSent[key] = now
        return true
    }
}
