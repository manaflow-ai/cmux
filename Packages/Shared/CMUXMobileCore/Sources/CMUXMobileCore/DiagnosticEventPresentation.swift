import Foundation

/// Decodes a ``DiagnosticEvent`` into stable, human-readable names and fields
/// for telemetry sinks (Sentry breadcrumbs, structured logs) and debug UI.
///
/// The compact ring export stays integer-only; this presentation layer is for
/// consumers that ship or display individual events and want them legible
/// without the offline decoder. Everything here is derived from the fixed
/// integer taxonomy, so the output is privacy-safe by construction: no free
/// text from errors, peers, accounts, or terminal content can appear.
///
/// Case names are part of the telemetry vocabulary (Sentry issue grouping and
/// search keys use them), so renaming a taxonomy case is a breaking telemetry
/// change; ``DiagnosticEventPresentationTests`` pins the names.
public enum DiagnosticEventPresentation {
    /// One decoded key/value pair of a described event.
    public struct Field: Sendable, Equatable {
        public let key: String
        public let value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// A described event: a stable dotted name plus decoded payload fields.
    public struct DescribedEvent: Sendable, Equatable {
        /// The stable event name, e.g. `transportDialFailed`.
        public let name: String
        /// Decoded payload fields in a stable order.
        public let fields: [Field]

        public init(name: String, fields: [Field]) {
            self.name = name
            self.fields = fields
        }
    }

    /// The stable name of an event code (its case name).
    public static func name(_ code: DiagnosticEventCode) -> String {
        String(describing: code)
    }

    /// The stable name of a failure kind (its case name).
    public static func name(_ kind: DiagnosticFailureKind) -> String {
        String(describing: kind)
    }

    /// The stable name of a transport kind (its case name).
    public static func name(_ kind: DiagnosticTransportKind) -> String {
        String(describing: kind)
    }

    /// The stable name of a path kind (its case name).
    public static func name(_ kind: DiagnosticPathKind) -> String {
        String(describing: kind)
    }

    /// The stable name of a session lifecycle kind (its case name).
    public static func name(_ kind: DiagnosticSessionLifecycleKind) -> String {
        String(describing: kind)
    }

    /// The stable name of an app lifecycle phase (its case name).
    public static func name(_ phase: DiagnosticAppLifecyclePhase) -> String {
        String(describing: phase)
    }

    /// The stable name of a runtime role (its case name).
    public static func name(_ role: DiagnosticRuntimeRole) -> String {
        String(describing: role)
    }

    /// Decodes an event's payload slots per its code's documented semantics.
    ///
    /// Unknown raw values render as their integer so a newer writer's event
    /// still describes usefully on an older reader.
    public static func describe(_ event: DiagnosticEvent) -> DescribedEvent {
        var fields: [Field] = []
        if let surface = event.surface {
            fields.append(Field(key: "surface", value: String(surface)))
        }
        if let ms = event.ms {
            fields.append(Field(key: msKey(for: event.code), value: String(ms)))
        }
        if let a = event.a {
            fields.append(decodeA(a, code: event.code))
        }
        if let b = event.b {
            fields.append(decodeB(b, code: event.code))
        }
        if let c = event.c {
            fields.append(Field(key: cKey(for: event.code), value: String(c)))
        }
        return DescribedEvent(name: name(event.code), fields: fields)
    }

    /// The failure kind carried in an event's `b` slot, when its code uses `b`
    /// for ``DiagnosticFailureKind``.
    public static func failureKind(of event: DiagnosticEvent) -> DiagnosticFailureKind? {
        guard codesWithFailureB.contains(event.code), let b = event.b else { return nil }
        return DiagnosticFailureKind(rawValue: b)
    }

    /// The transport kind carried in an event's `a` slot, when its code uses
    /// `a` for ``DiagnosticTransportKind``.
    public static func transportKind(of event: DiagnosticEvent) -> DiagnosticTransportKind? {
        guard codesWithTransportA.contains(event.code), let a = event.a else { return nil }
        return DiagnosticTransportKind(rawValue: a)
    }

    /// Event codes whose `b` slot carries a ``DiagnosticFailureKind``.
    static let codesWithFailureB: Set<DiagnosticEventCode> = [
        .pairFail, .transportDialFailed, .recoveryFailed, .endpointFailed,
        .relayPolicyRefreshFailed, .sessionClosed, .routeUnavailable,
        .discoveryFailed, .admissionFailed, .hostAuthenticationFailed,
        .rpcFailed, .transportCloseAttribution,
    ]

    /// Event codes whose `a` slot carries a ``DiagnosticTransportKind``.
    static let codesWithTransportA: Set<DiagnosticEventCode> = [
        .pairFail, .transportDialStarted, .transportDialConnected,
        .transportDialFailed, .sessionClosed, .routeUnavailable,
    ]

    private static func msKey(for code: DiagnosticEventCode) -> String {
        switch code {
        case .retryScheduled:
            return "delay_ms"
        case .transportCloseAttribution:
            return "app_error_code"
        case .composerActiveTransition:
            return "keyboard_height"
        default:
            return "ms"
        }
    }

    private static func cKey(for code: DiagnosticEventCode) -> String {
        switch code {
        case .transportDialStarted, .transportDialConnected, .transportDialFailed:
            return "attempt_id"
        case .sessionClosed, .transportSessionLifecycle,
             .transportCloseAttribution, .transportPathEvent:
            return "session_id"
        default:
            return "c"
        }
    }

    private static func decodeA(_ a: Int, code: DiagnosticEventCode) -> Field {
        switch code {
        case .pairFail, .transportDialStarted, .transportDialConnected,
             .transportDialFailed, .sessionClosed, .routeUnavailable:
            return enumField(key: "transport", raw: a) { DiagnosticTransportKind(rawValue: $0).map(name) }
        case .selectedPathChanged:
            return enumField(key: "path", raw: a) { DiagnosticPathKind(rawValue: $0).map(name) }
        case .transportSessionLifecycle:
            return enumField(key: "lifecycle", raw: a) { DiagnosticSessionLifecycleKind(rawValue: $0).map(name) }
        case .appLifecycleChanged:
            return enumField(key: "phase", raw: a) { DiagnosticAppLifecyclePhase(rawValue: $0).map(name) }
        case .reachabilityChanged:
            return Field(key: "reachable", value: a == 1 ? "true" : "false")
        case .transportCloseAttribution:
            return enumField(key: "initiator", raw: a) { closeInitiatorNames[$0] }
        case .transportPathEvent:
            return enumField(key: "path_event", raw: a) { pathEventNames[$0] }
        default:
            return Field(key: "a", value: String(a))
        }
    }

    private static func decodeB(_ b: Int, code: DiagnosticEventCode) -> Field {
        if codesWithFailureB.contains(code) {
            return enumField(key: "failure", raw: b) { DiagnosticFailureKind(rawValue: $0).map(name) }
        }
        switch code {
        case .transportSessionLifecycle:
            return Field(key: "purpose", value: String(b))
        case .transportPathEvent:
            return enumField(key: "path", raw: b) { DiagnosticPathKind(rawValue: $0).map(name) }
        default:
            return Field(key: "b", value: String(b))
        }
    }

    private static func enumField(
        key: String,
        raw: Int,
        name: (Int) -> String?
    ) -> Field {
        Field(key: key, value: name(raw) ?? String(raw))
    }

    /// Close-initiator names for ``DiagnosticEventCode/transportCloseAttribution``'s `a`.
    private static let closeInitiatorNames: [Int: String] = [
        0: "unknown", 1: "local", 2: "remote", 3: "timedOut",
    ]

    /// Path-event names for ``DiagnosticEventCode/transportPathEvent``'s `a`.
    private static let pathEventNames: [Int: String] = [
        1: "opened", 2: "closed", 3: "selected", 4: "lagged",
    ]
}
