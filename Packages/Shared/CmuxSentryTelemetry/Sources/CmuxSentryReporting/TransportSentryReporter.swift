public import CMUXMobileCore
public import Foundation
public import Sentry
internal import os

/// Bridges the transport diagnostic event stream into Sentry so any user's
/// connection failure is diagnosable remotely, on both the iOS client and the
/// macOS host. Simulator streaming/control events use the same integer-only
/// diagnostic ring and are delivered under a separate `simulator` telemetry
/// namespace.
///
/// Wire an instance as the ``CMUXMobileCore/DiagnosticLog`` event tap from the
/// composition root. Each retained event becomes:
///
/// 1. A Sentry **breadcrumb** (category `transport`, `simulator`, or `app`), so
///    every subsequent event, including crashes, hangs, and watchdog kills,
///    carries the recent connection and feature timeline.
/// 2. A budget-limited Sentry **structured log** line (when the SDK started
///    with `enableLogs`), searchable without waiting for an error.
/// 3. When it crosses ``CMUXMobileCore/TransportIncidentPolicy``'s capture
///    gates, a Sentry **event** fingerprinted by the failure signature and
///    carrying the plain-language diagnostic timeline as an attachment.
///
/// Privacy: everything sent derives from the fixed integer diagnostic
/// taxonomy, so no free text, peer identity, address, account, or terminal
/// content can appear. The SDK-level scrubbers still run over all of it.
///
/// `ingest(_:)` is called on the diagnostic ring's drain task; it does its
/// synchronous work (breadcrumb, log, policy decision) inline and defers the
/// ring export + event capture to a task so the drain is never blocked.
public final class TransportSentryReporter: Sendable {
    /// Delivery seams to the Sentry SDK, injectable for tests.
    public struct Delivery: Sendable {
        /// Whether telemetry is currently deliverable (SDK started, consent on).
        public var isEnabled: @Sendable () -> Bool
        /// Records one breadcrumb.
        public var addBreadcrumb: @Sendable (Breadcrumb) -> Void
        /// Captures one event with an optional attachment.
        public var capture: @Sendable (Event, Attachment?) -> Void
        /// Emits one structured log line.
        public var log: @Sendable (LogLevel, String, [String: Any]) -> Void

        public init(
            isEnabled: @escaping @Sendable () -> Bool,
            addBreadcrumb: @escaping @Sendable (Breadcrumb) -> Void,
            capture: @escaping @Sendable (Event, Attachment?) -> Void,
            log: @escaping @Sendable (LogLevel, String, [String: Any]) -> Void
        ) {
            self.isEnabled = isEnabled
            self.addBreadcrumb = addBreadcrumb
            self.capture = capture
            self.log = log
        }

        /// The production delivery, talking to the live `SentrySDK`.
        public static func sentry() -> Delivery {
            Delivery(
                isEnabled: { SentrySDK.isEnabled },
                addBreadcrumb: { SentrySDK.addBreadcrumb($0) },
                capture: { event, attachment in
                    SentrySDK.capture(event: event) { scope in
                        if let attachment {
                            scope.addAttachment(attachment)
                        }
                    }
                },
                log: { level, message, attributes in
                    switch level {
                    case .info:
                        SentrySDK.logger.info(message, attributes: attributes)
                    case .warning:
                        SentrySDK.logger.warn(message, attributes: attributes)
                    case .error:
                        SentrySDK.logger.error(message, attributes: attributes)
                    }
                }
            )
        }
    }

    /// Structured-log severity, decoupled from Sentry's type so tests need no SDK.
    public enum LogLevel: Sendable, Equatable {
        case info
        case warning
        case error
    }

    private struct MutableState: Sendable {
        var policy: TransportIncidentPolicy
        var logBudget: TransportTelemetryLogBudget
    }

    private struct TelemetryNamespace: Sendable {
        let name: String
        let attributePrefix: String
    }

    private let roleCode: String
    private let roleDisplayName: String
    private let exportRing: @Sendable () async -> Data
    private let delivery: Delivery
    // lint:allow lock - ingest is synchronous on the diagnostic drain task; the
    // critical region only advances the pure policy/budget state machines.
    private let state: OSAllocatedUnfairLock<MutableState>

    /// Creates a reporter.
    ///
    /// - Parameters:
    ///   - role: The producing runtime (`mobileClient` on iOS, `macHost` on
    ///     macOS); rides as a tag and fingerprint component.
    ///   - exportRing: Snapshot of the diagnostic ring's plain-language report,
    ///     attached to captured incidents. Pass the owning log's `export`.
    ///   - incidentConfiguration: Capture-gate thresholds.
    ///   - logsPerHour: Sliding-hour budget for structured log lines.
    ///   - delivery: SDK seams; defaults to the live Sentry SDK.
    public init(
        role: DiagnosticRuntimeRole,
        exportRing: @escaping @Sendable () async -> Data,
        incidentConfiguration: TransportIncidentPolicy.Configuration = .init(),
        logsPerHour: Int = 300,
        delivery: Delivery = .sentry()
    ) {
        self.roleCode = DiagnosticEventPresentation().name(role)
        self.roleDisplayName = DiagnosticEventPresentation().displayName(role)
        self.exportRing = exportRing
        self.delivery = delivery
        self.state = OSAllocatedUnfairLock(initialState: MutableState(
            policy: TransportIncidentPolicy(configuration: incidentConfiguration),
            logBudget: TransportTelemetryLogBudget(capacityPerHour: logsPerHour)
        ))
    }

    /// Ingests one diagnostic event, in ring order. Safe to install directly
    /// as ``CMUXMobileCore/DiagnosticLog/setEventTap(_:)``'s observer.
    public func ingest(_ event: DiagnosticEvent) {
        guard delivery.isEnabled() else { return }

        let described = DiagnosticEventPresentation().describe(event)
        let level = telemetryLevel(for: event)

        let (incident, logDropCount) = state.withLock { state in
            (state.policy.decide(event), state.logBudget.admit(tNanos: event.tNanos))
        }

        deliverBreadcrumb(event, described: described, level: level)
        if let logDropCount {
            deliverLog(
                event,
                described: described,
                level: level,
                droppedBeforeThis: logDropCount
            )
        }
        if let incident {
            captureIncident(incident)
        }
    }

    private func deliverBreadcrumb(
        _ event: DiagnosticEvent,
        described: DiagnosticEventPresentation.DescribedEvent,
        level: LogLevel
    ) {
        let namespace = telemetryNamespace(for: event.code)
        let crumb = Breadcrumb(level: sentryLevel(for: level), category: namespace.name)
        crumb.type = level == .info ? "default" : "error"
        crumb.message = DiagnosticEventPresentation().summary(described)
        var data: [String: Any] = [
            "diagnostic.category": namespace.name,
            "event_code": DiagnosticEventPresentation().name(event.code),
            "role": roleDisplayName,
        ]
        for field in described.fields {
            data[field.key] = field.value
        }
        crumb.data = data
        delivery.addBreadcrumb(crumb)
    }

    private func deliverLog(
        _ event: DiagnosticEvent,
        described: DiagnosticEventPresentation.DescribedEvent,
        level: LogLevel,
        droppedBeforeThis: Int
    ) {
        let namespace = telemetryNamespace(for: event.code)
        var attributes: [String: Any] = [
            "diagnostic.category": namespace.name,
            "\(namespace.attributePrefix).event_code": DiagnosticEventPresentation().name(event.code),
            "\(namespace.attributePrefix).role": roleDisplayName,
            "\(namespace.attributePrefix).role_code": roleCode,
        ]
        for field in described.fields {
            attributes["\(namespace.attributePrefix).\(field.key)"] = field.value
        }
        if droppedBeforeThis > 0 {
            attributes["\(namespace.attributePrefix).log_dropped_before_this"] = droppedBeforeThis
        }
        delivery.log(
            level,
            DiagnosticEventPresentation().summary(described),
            attributes
        )
    }

    private func telemetryNamespace(for code: DiagnosticEventCode) -> TelemetryNamespace {
        if code.isSimulatorDiagnosticEvent {
            return TelemetryNamespace(name: "simulator", attributePrefix: "simulator")
        }
        if code.isAppFeatureDiagnosticEvent {
            return TelemetryNamespace(name: "app", attributePrefix: "app")
        }
        return TelemetryNamespace(name: "transport", attributePrefix: "transport")
    }

    private func sentryLevel(for level: LogLevel) -> SentryLevel {
        switch level {
        case .info:
            return .info
        case .warning:
            return .warning
        case .error:
            return .error
        }
    }

    private func telemetryLevel(for event: DiagnosticEvent) -> LogLevel {
        if TransportIncidentPolicy.failureCodes.contains(event.code) {
            return .warning
        }
        if event.code.isAppFeatureDiagnosticEvent {
            guard let failureRaw = event.b,
                  failureRaw != DiagnosticFailureKind.none.rawValue
            else { return .info }
            return .warning
        }
        guard event.code.isSimulatorDiagnosticEvent else {
            return .info
        }
        switch event.code {
        case .simulatorStreamLifecycle:
            guard let a = event.a,
                  let state = DiagnosticSimulatorStreamLifecycle(rawValue: a)
            else { return .warning }
            switch state {
            case .locked, .startFailed, .stopFailed, .stalled:
                return .warning
            case .startRequested, .started, .stopRequested, .stopped,
                 .closed, .restartRequested, .pausedForBackground,
                 .descriptorApplied:
                return .info
            }
        case .simulatorFrameLifecycle:
            guard let a = event.a,
                  let state = DiagnosticSimulatorFrameLifecycle(rawValue: a)
            else { return .warning }
            switch state {
            case .readerMissing, .encodeFailed, .refused, .decodeFailed,
                 .imageDecodeFailed, .unknownPanel:
                return .warning
            case .readerAttached, .copied, .sent, .cachedSent,
                 .subscriptionReasserted, .received, .staleIgnored,
                 .imageDecoded:
                return .info
            }
        case .simulatorInputLifecycle:
            guard let a = event.a,
                  let state = DiagnosticSimulatorInputLifecycle(rawValue: a)
            else { return .warning }
            switch state {
            case .failed, .rejectedLocked, .unavailable, .invalidParameters,
                 .panelMissing, .featureDisabled, .blockedViewOnly:
                return .warning
            case .queued, .sent, .accepted:
                return .info
            }
        case .simulatorCoordinateMapped:
            guard let c = event.c,
                  let state = DiagnosticSimulatorCoordinateState(rawValue: c)
            else { return .warning }
            return state == .mapped ? .info : .warning
        case .simulatorOwnershipChanged:
            return .info
        default:
            return .info
        }
    }

    private func captureIncident(_ incident: TransportIncidentPolicy.Incident) {
        Task.detached(priority: .utility) { [self] in
            let ring = await exportRing()
            let attachment = ring.isEmpty ? nil : Attachment(
                data: ring,
                filename: "cmux-transport-diag.txt",
                contentType: "text/plain"
            )
            delivery.capture(makeEvent(incident), attachment)
        }
    }

    /// Builds the Sentry event for an incident. Grouping comes from the
    /// explicit fingerprint (role + policy signature), never from the message,
    /// so coalesced-count suffixes cannot split issues.
    private nonisolated func makeEvent(_ incident: TransportIncidentPolicy.Incident) -> Event {
        let event = Event(level: incident.severity == .error ? .error : .warning)
        event.message = SentryMessage(formatted: incident.title)
        event.logger = "cmux.transport"
        event.fingerprint = ["cmux-transport", roleCode, incident.signature]

        var tags: [String: String] = [
            "transport.event": DiagnosticEventPresentation().name(incident.event.code),
            "transport.signature": incident.signature,
            "transport.role": roleCode,
            "transport.incident": incident.kind == .outage ? "outage" : "failure",
        ]
        if let failure = incident.failure {
            tags["transport.failure"] = DiagnosticEventPresentation().name(failure)
        }
        if let transport = incident.transport {
            tags["transport.kind"] = DiagnosticEventPresentation().name(transport)
        }
        event.tags = tags

        var context: [String: Any] = [
            "coalesced_count": incident.coalescedCount,
            "consecutive_failures": incident.consecutiveFailures,
            "dropped_by_budget": incident.droppedByBudget,
        ]
        if let seconds = incident.secondsSinceFirstCoalesced {
            context["seconds_since_first_coalesced"] = Int(seconds.rounded())
        }
        if let seconds = incident.secondsSinceLastSuccess {
            context["seconds_since_last_success"] = Int(seconds.rounded())
        }
        if let reachable = incident.reachable {
            context["reachable"] = reachable
        }
        if let phase = incident.appPhase {
            context["app_phase"] = DiagnosticEventPresentation().displayName(phase)
            context["app_phase_code"] = DiagnosticEventPresentation().name(phase)
        }
        let described = DiagnosticEventPresentation().describe(incident.event)
        for field in described.fields {
            context["event_\(field.key)"] = field.value
        }
        event.context = ["cmux.transport": context]
        return event
    }
}
