import Foundation

/// A bounded, privacy-safe snapshot of recent app-transport diagnostics.
///
/// The report contains only stable integer enums, timestamps, bounded event
/// payloads, a sanitized build stamp, and the runtime role. It has no fields for
/// addresses, endpoint IDs, account identifiers, relay URLs, tokens, terminal
/// content, or raw error descriptions.
public struct DiagnosticReport: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1
    /// Version of the plain-language text report format.
    public static let currentHumanReadableFormatVersion = 2
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
    /// A `cancelled` outcome is an abandoned attempt, not a failure: callers
    /// cancel dials on supersession and teardown, so surfacing one here would
    /// report routine churn as the connection's latest problem.
    public var lastFailureEvent: DiagnosticEvent? {
        events.last(where: { event in
            if let kind = event.diagnosticFailureKind {
                return kind != .none && kind != .cancelled
            }
            return event.code.isDiagnosticFailure
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

    /// Encodes this exact snapshot as a self-contained plain-language report.
    ///
    /// Absolute UTC timestamps are used when the snapshot has a wall-clock
    /// anchor. Archived or synthetic reports without an anchor use elapsed
    /// seconds from their first event. Both forms require no external decoder.
    /// - Parameter locale: Locale used for report headings and event text.
    /// - Returns: UTF-8 data containing the complete report.
    public func humanReadableExport(locale: Locale = .current) -> Data {
        let localization = DiagnosticLocalization(locale: locale)
        let presentation = DiagnosticEventPresentation(locale: locale)
        let formatter = Self.makeUTCDateFormatter()
        var out = ""
        out.reserveCapacity(320 + events.count * 160)
        out += localization.string(
            "diagnostics.report.title",
            defaultValue: "cmux Iroh and transport report"
        ) + "\n"
        out += localization.string(
            "diagnostics.report.format",
            defaultValue: "Report format: \(Self.currentHumanReadableFormatVersion)"
        ) + "\n"
        let generated = formatter.string(from: generatedAt)
        out += localization.string(
            "diagnostics.report.generated",
            defaultValue: "Generated: \(generated)"
        ) + "\n"
        let source = presentation.displayName(role)
        out += localization.string(
            "diagnostics.report.source",
            defaultValue: "Source: \(source)"
        ) + "\n"
        if !buildStamp.isEmpty {
            out += localization.string(
                "diagnostics.report.build",
                defaultValue: "Build: \(buildStamp)"
            ) + "\n"
        }
        out += localization.string(
            "diagnostics.report.eventCount",
            defaultValue: "Event count: \(events.count)"
        ) + "\n\n"
        out += localization.string(
            "diagnostics.report.timeline",
            defaultValue: "Timeline (oldest first)"
        ) + "\n"

        guard let firstEvent = events.first else {
            out += localization.string(
                "diagnostics.report.empty",
                defaultValue: "No events recorded."
            ) + "\n"
            return Data(out.utf8)
        }

        let relativeSecondsUnit = localization.string(
            "diagnostics.report.relativeSecondsUnit",
            defaultValue: "seconds"
        )
        for event in events {
            let timestamp: String
            if let date = wallDate(for: event) {
                timestamp = formatter.string(from: date)
            } else {
                timestamp = Self.relativeTimestamp(
                    from: firstEvent.tNanos,
                    to: event.tNanos,
                    secondsUnit: relativeSecondsUnit
                )
            }
            out += "\(timestamp) | \(presentation.summary(event))\n"
        }
        return Data(out.utf8)
    }

    /// Formats this report away from a caller's actor executor.
    ///
    /// - Parameter locale: Locale used for report headings and event text.
    /// - Returns: The complete UTF-8 report decoded as a string.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    public nonisolated func humanReadableText(locale: Locale = .current) async -> String {
        String(decoding: humanReadableExport(locale: locale), as: UTF8.self)
    }

    /// Source-compatible spelling retained for existing report consumers.
    /// The returned data is the same plain-language report as
    /// ``humanReadableExport()`` and contains no compact integer rows.
    public func compactExport() -> Data {
        humanReadableExport()
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

    private static func makeUTCDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS 'UTC'"
        return formatter
    }

    private static func relativeTimestamp(
        from firstNanos: UInt64,
        to eventNanos: UInt64,
        secondsUnit: String
    ) -> String {
        let elapsedNanos = eventNanos >= firstNanos ? eventNanos - firstNanos : 0
        let wholeMilliseconds = elapsedNanos / 1_000_000
        let roundedMilliseconds = wholeMilliseconds
            + (elapsedNanos % 1_000_000 >= 500_000 ? 1 : 0)
        let seconds = roundedMilliseconds / 1_000
        let milliseconds = roundedMilliseconds % 1_000
        let fraction: String
        if milliseconds < 10 {
            fraction = "00\(milliseconds)"
        } else if milliseconds < 100 {
            fraction = "0\(milliseconds)"
        } else {
            fraction = String(milliseconds)
        }
        return "+\(seconds).\(fraction) \(secondsUnit)"
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
        guard code.isTransportDialEvent || code == .transportDialSessionLinked
                || code == .transportDialCancelled,
              let c,
              c > 0 else { return nil }
        return c
    }

    /// Positive process-local session correlation ID carried by a dial/session
    /// link or close-reason event.
    var diagnosticLinkedSessionID: Int? {
        guard code == .transportDialSessionLinked || code == .transportCloseReason,
              let c,
              c > 0 else { return nil }
        return c
    }

    /// Redacted path class carried by a selected-path or path-lifecycle event.
    var diagnosticPathKind: DiagnosticPathKind? {
        guard code == .selectedPathChanged || code == .transportPathEvent,
              let rawValue = code == .transportPathEvent ? b : a else {
            return nil
        }
        return DiagnosticPathKind(rawValue: rawValue)
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
        guard code == .transportSessionLifecycle
                || code == .sessionClosed
                || code == .transportCloseAttribution
                || code == .transportCloseReason
                || code == .transportPathEvent,
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
             .transportDialLegFailed,
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
             .transportDialLegFailed,
             .recoveryFailed,
             .endpointFailed,
             .relayPolicyRefreshFailed,
             .sessionClosed,
             .transportCloseAttribution,
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
             .transportDialLegFailed,
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
