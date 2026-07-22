import Foundation

/// A bounded, privacy-safe snapshot of recent app-transport diagnostics.
///
/// The report contains only stable integer enums, timestamps, bounded event
/// payloads, a sanitized build stamp, and the runtime role. It has no fields for
/// addresses, endpoint IDs, account identifiers, relay URLs, tokens, terminal
/// content, or raw error descriptions.
public struct DiagnosticReport: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1
    public static let maximumEventCount = 4_096

    /// A deterministic report suitable as a controller's unavailable default.
    public static let empty = DiagnosticReport(
        role: .unspecified,
        generatedAt: Date(timeIntervalSince1970: 0),
        anchorWallNanos: 0,
        anchorMonotonicNanos: 0,
        buildStamp: "",
        events: []
    )

    public let schemaVersion: Int
    public let role: DiagnosticRuntimeRole
    public let generatedAt: Date
    public let anchorWallNanos: UInt64
    public let anchorMonotonicNanos: UInt64
    public let buildStamp: String
    /// Events ordered by monotonic timestamp, oldest first.
    public let events: [DiagnosticEvent]

    public init(
        schemaVersion: Int = DiagnosticReport.currentSchemaVersion,
        role: DiagnosticRuntimeRole = .unspecified,
        generatedAt: Date = Date(),
        anchorWallNanos: UInt64 = 0,
        anchorMonotonicNanos: UInt64 = 0,
        buildStamp: String = "",
        events: [DiagnosticEvent] = []
    ) {
        self.schemaVersion = schemaVersion
        self.role = role
        self.generatedAt = generatedAt
        self.anchorWallNanos = anchorWallNanos
        self.anchorMonotonicNanos = anchorMonotonicNanos
        self.buildStamp = Self.sanitizeBuildStamp(buildStamp)
        let retainedEvents = events.suffix(Self.maximumEventCount)
        let orderedEvents = retainedEvents
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.tNanos == rhs.element.tNanos {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.tNanos < rhs.element.tNanos
            }
            .map(\.element)
        self.events = orderedEvents
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case role
        case generatedAt
        case anchorWallNanos
        case anchorMonotonicNanos
        case buildStamp
        case events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var eventsContainer = try container.nestedUnkeyedContainer(forKey: .events)
        var events: [DiagnosticEvent] = []
        events.reserveCapacity(min(eventsContainer.count ?? 0, Self.maximumEventCount))
        while !eventsContainer.isAtEnd, events.count < Self.maximumEventCount {
            events.append(try eventsContainer.decode(DiagnosticEvent.self))
        }
        guard eventsContainer.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: eventsContainer,
                debugDescription: "Diagnostic report exceeds the maximum event count."
            )
        }
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            role: try container.decode(DiagnosticRuntimeRole.self, forKey: .role),
            generatedAt: try container.decode(Date.self, forKey: .generatedAt),
            anchorWallNanos: try container.decode(UInt64.self, forKey: .anchorWallNanos),
            anchorMonotonicNanos: try container.decode(UInt64.self, forKey: .anchorMonotonicNanos),
            buildStamp: try container.decode(String.self, forKey: .buildStamp),
            events: events
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(role, forKey: .role)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(anchorWallNanos, forKey: .anchorWallNanos)
        try container.encode(anchorMonotonicNanos, forKey: .anchorMonotonicNanos)
        try container.encode(buildStamp, forKey: .buildStamp)
        try container.encode(events, forKey: .events)
    }

    /// Maps one event's monotonic timestamp onto the report's wall-clock
    /// anchor. Empty/default reports have no usable anchor and return `nil`.
    public func wallDate(for event: DiagnosticEvent) -> Date? {
        wallDate(forMonotonicNanos: event.tNanos)
    }

    /// Maps a monotonic timestamp onto the report's wall-clock anchor.
    public func wallDate(forMonotonicNanos nanos: UInt64) -> Date? {
        guard anchorWallNanos > 0, anchorMonotonicNanos > 0 else { return nil }
        let deltaNanos: Double
        if nanos >= anchorMonotonicNanos {
            deltaNanos = Double(nanos - anchorMonotonicNanos)
        } else {
            deltaNanos = -Double(anchorMonotonicNanos - nanos)
        }
        let wallSeconds = Double(anchorWallNanos) / 1_000_000_000
        return Date(timeIntervalSince1970: wallSeconds + (deltaNanos / 1_000_000_000))
    }

    /// The latest event that marks a usable connection/lifecycle milestone.
    public var lastSuccessEvent: DiagnosticEvent? {
        events.last(where: { $0.code.isDiagnosticSuccess })
    }

    /// The latest event that marks a failed connection/lifecycle milestone.
    public var lastFailureEvent: DiagnosticEvent? {
        events.last(where: { event in
            event.code.isDiagnosticFailure
                || event.diagnosticFailureKind.map { $0 != .none } == true
        })
    }

    /// Wall-clock time of the most recent successful transport connection.
    public var lastTransportConnectionDate: Date? {
        guard let event = events.last(where: { $0.code == .transportDialConnected }) else {
            return nil
        }
        return wallDate(for: event)
    }

    /// Wall-clock time of the most recent authenticated app connection. A
    /// client reports dial/auth/RPC milestones, while a host reports admission,
    /// so this helper works for either runtime role.
    public var lastConnectionSuccessDate: Date? {
        guard let event = events.last(where: { event in
            switch event.code {
            case .transportDialConnected, .hostAuthenticated, .rpcReady, .admissionSucceeded:
                true
            default:
                false
            }
        }) else {
            return nil
        }
        return wallDate(for: event)
    }

    /// Wall-clock time of the most recent classified failure event.
    public var lastFailureDate: Date? {
        guard let event = lastFailureEvent else { return nil }
        return wallDate(for: event)
    }

    /// Privacy-safe category of the most recent failure event.
    public var lastFailureKind: DiagnosticFailureKind? {
        guard let event = lastFailureEvent else { return nil }
        if let kind = event.diagnosticFailureKind, kind != .none {
            return kind
        }
        return event.code.defaultDiagnosticFailureKind
    }

    /// Encodes this exact snapshot in the compact, human-shareable v1 format.
    /// Building the share payload from the snapshot prevents live events from
    /// making the displayed summary and exported timeline disagree.
    public func compactExport() -> Data {
        var out = "cmuxdiag v1"
        out += " anchorWallNs=\(anchorWallNanos)"
        out += " anchorMonoNs=\(anchorMonotonicNanos)"
        out += " count=\(events.count)"
        out += " role=\(role.rawValue)"
        if !buildStamp.isEmpty {
            out += " build=\(buildStamp)"
        }
        out += "\n"
        for event in events {
            out += "\(event.tNanos),\(event.code.rawValue)"
            out += ",\(Self.field(event.surface))"
            out += ",\(Self.field(event.ms))"
            out += ",\(Self.field(event.a))"
            out += ",\(Self.field(event.b))"
            out += ",\(Self.field(event.c))"
            out += "\n"
        }
        return Data(out.utf8)
    }

    /// Removes control characters, path separators, and unbounded caller data
    /// from the build stamp before it enters an export.
    static func sanitizeBuildStamp(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(min(96, value.utf8.count))
        for scalar in value.unicodeScalars {
            let raw = scalar.value
            let isASCIIAlphaNumeric = (48...57).contains(raw)
                || (65...90).contains(raw)
                || (97...122).contains(raw)
            let isAllowedPunctuation = raw == 32
                || raw == 40
                || raw == 41
                || raw == 43
                || raw == 45
                || raw == 46
                || raw == 95
            guard isASCIIAlphaNumeric || isAllowedPunctuation else { continue }
            guard result.utf8.count + scalar.utf8.count <= 96 else { break }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    private static func field(_ value: (some BinaryInteger)?) -> String {
        guard let value else { return "" }
        return String(value)
    }
}

public extension DiagnosticEvent {
    /// Transport category carried by a dial event's `a` slot.
    var diagnosticTransportKind: DiagnosticTransportKind? {
        guard code.isTransportDialEvent, let a else {
            return nil
        }
        return DiagnosticTransportKind(rawValue: a)
    }

    /// Failure category carried by a failure event's `b` slot.
    var diagnosticFailureKind: DiagnosticFailureKind? {
        guard code.carriesDiagnosticFailureKind,
              let b
        else {
            return nil
        }
        return DiagnosticFailureKind(rawValue: b)
    }

    /// Positive process-local correlation ID shared by a dial attempt and its
    /// outcome. It is intentionally not stable across launches or devices.
    var diagnosticAttemptID: Int? {
        guard code.isTransportDialEvent, let c, c > 0 else { return nil }
        return c
    }

    /// Redacted path class carried by ``DiagnosticEventCode/selectedPathChanged``.
    var diagnosticPathKind: DiagnosticPathKind? {
        guard code == .selectedPathChanged, let a else {
            return nil
        }
        return DiagnosticPathKind(rawValue: a)
    }

    /// Privacy-safe pool transition carried by
    /// ``DiagnosticEventCode/transportSessionLifecycle``.
    var diagnosticSessionLifecycleKind: DiagnosticSessionLifecycleKind? {
        guard code == .transportSessionLifecycle, let a else { return nil }
        return DiagnosticSessionLifecycleKind(rawValue: a)
    }

    /// Local owner role carried by a transport-session lifecycle event.
    var diagnosticSessionPurpose: CmxTransportSessionPurpose? {
        guard code == .transportSessionLifecycle,
              let b,
              let raw = UInt8(exactly: b) else { return nil }
        return CmxTransportSessionPurpose(rawValue: raw)
    }

    /// Positive process-local session correlation ID. This value is not stable
    /// across app launches or devices.
    var diagnosticSessionID: Int? {
        guard code == .transportSessionLifecycle || code == .sessionClosed,
              let c,
              c > 0 else { return nil }
        return c
    }
}

public extension DiagnosticEventCode {
    var isTransportDialEvent: Bool {
        switch self {
        case .transportDialStarted, .transportDialConnected, .transportDialFailed:
            true
        default:
            false
        }
    }

    var isDiagnosticSuccess: Bool {
        switch self {
        case .pairOk,
             .transportDialConnected,
             .hostAuthenticated,
             .rpcReady,
             .recoverySucceeded,
             .endpointActive,
             .relayPolicyRefreshSucceeded,
             .discoverySucceeded,
             .admissionSucceeded:
            true
        default:
            false
        }
    }

    var isDiagnosticFailure: Bool {
        switch self {
        case .pairFail,
             .pairUnreachable,
             .streamEnded,
             .error,
             .transportDialFailed,
             .recoveryFailed,
             .endpointFailed,
             .relayPolicyRefreshFailed,
             .routeUnavailable,
             .discoveryFailed,
             .admissionFailed,
             .hostAuthenticationFailed,
             .rpcFailed:
            true
        default:
            false
        }
    }

    var carriesDiagnosticFailureKind: Bool {
        switch self {
        case .transportDialFailed,
             .recoveryFailed,
             .endpointFailed,
             .relayPolicyRefreshFailed,
             .sessionClosed,
             .routeUnavailable,
             .discoveryFailed,
             .admissionFailed,
             .hostAuthenticationFailed,
             .rpcFailed:
            true
        default:
            false
        }
    }

    var defaultDiagnosticFailureKind: DiagnosticFailureKind? {
        switch self {
        case .pairUnreachable:
            .offline
        case .streamEnded:
            .connectionClosed
        case .routeUnavailable:
            .noRoute
        case .pairFail,
             .error,
             .transportDialFailed,
             .recoveryFailed,
             .endpointFailed,
             .relayPolicyRefreshFailed,
             .discoveryFailed,
             .admissionFailed,
             .hostAuthenticationFailed,
             .rpcFailed:
            .unknown
        default:
            nil
        }
    }
}
