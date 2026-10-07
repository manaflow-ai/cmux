import Foundation

/// The bounded, privacy-reviewed shape accepted by the iOS analytics proxy.
///
/// This is deliberately a contract only. It does not perform network or disk
/// work; a future emitter can validate a batch here before handing it to an
/// uploader. Keeping the limits in the shared core prevents a transport from
/// accidentally accepting arbitrary event names or unbounded property bags.
public enum AnalyticsWireContract {
    /// The proxy's maximum body size for a batch.
    public static let maxRequestBytes = 64 * 1024
    /// The proxy's maximum number of events in one request.
    public static let maxBatchEvents = 100
    /// The proxy's maximum property count for one event.
    public static let maxEventProperties = 64
    /// Maximum byte length for identifiers, event names, and property keys.
    public static let maxIdentifierBytes = 128
    /// Maximum byte length for an enum-like string property.
    public static let maxStringValueBytes = 256

    /// Names currently accepted by `POST /api/analytics/events`.
    ///
    /// Keep this list in sync with `web/services/analytics/iosEventPolicy.ts`.
    /// Unknown names are rejected locally so they cannot be buffered forever
    /// only to receive a permanent 4xx from the proxy.
    public static let allowedEventNames: Set<String> = [
        "$identify",
        "ios_paywall_viewed",
        "ios_purchase_started",
        "ios_purchase_cancelled",
        "ios_purchase_failed",
        "ios_purchase_pending",
        "ios_restore_started",
        "ios_restore_completed",
        "ios_app_first_launch",
        "ios_app_launched",
        "ios_app_foregrounded",
        "ios_app_backgrounded",
        "ios_session_started",
        "ios_session_ended",
        "ios_sign_in_started",
        "ios_sign_in_completed",
        "ios_sign_in_failed",
        "ios_sign_in_cancelled",
        "ios_billing_recovery_attempted",
        "ios_billing_recovery_failed",
        "ios_pairing_screen_viewed",
        "ios_pairing_started",
        "ios_pairing_succeeded",
        "ios_pairing_failed",
        "ios_connection_lost",
        "ios_connection_recovered",
        "ios_connection_recovery_failed",
        "ios_initial_connection",
        "ios_workspace_opened",
        "ios_first_frame_latency",
        "ios_terminal_input_submitted",
        "ios_terminal_input_dropped",
        "ios_push_optin_prompt_shown",
        "ios_push_optin_granted",
        "ios_push_optin_declined",
        "ios_push_token_registration_failed",
        "ios_push_tapped",
        "ios_push_deeplink_resolved",
        "ios_push_deeplink_failed",
        "ios_crash",
    ]

    public static func validate(_ event: AnalyticsWireEvent) throws {
        guard allowedEventNames.contains(event.name) else {
            throw AnalyticsWireError.eventNameNotAllowed(event.name)
        }
        try validateIdentifier(event.name, kind: .eventName)
        if let distinctID = event.distinctID {
            try validateIdentifier(distinctID, kind: .distinctID)
        }
        if let anonymousID = event.anonymousID {
            try validateIdentifier(anonymousID, kind: .anonymousID)
        }
        let aliasesOneMoreProperty = event.anonymousID != nil && event.properties["$anon_distinct_id"] == nil
        let wirePropertyCount = event.properties.count + (aliasesOneMoreProperty ? 1 : 0)
        guard wirePropertyCount <= maxEventProperties else {
            throw AnalyticsWireError.propertyCountExceeded(wirePropertyCount)
        }
        for (key, value) in event.properties {
            try validateIdentifier(key, kind: .propertyKey)
            try validate(value, property: key)
        }
    }

    public static func validate(_ batch: AnalyticsWireBatch) throws {
        guard batch.events.count <= maxBatchEvents else {
            throw AnalyticsWireError.batchCountExceeded(batch.events.count)
        }
        for event in batch.events {
            try validate(event)
        }
    }

    private enum IdentifierKind: String {
        case eventName
        case distinctID
        case anonymousID
        case propertyKey
    }

    private static func validateIdentifier(_ value: String, kind: IdentifierKind) throws {
        guard !value.isEmpty, value.utf8.count <= maxIdentifierBytes else {
            throw AnalyticsWireError.identifierTooLong(kind: kind.rawValue, byteCount: value.utf8.count)
        }
    }

    private static func validate(_ value: AnalyticsValue, property: String) throws {
        switch value {
        case let .string(string):
            guard string.utf8.count <= maxStringValueBytes else {
                throw AnalyticsWireError.stringValueTooLong(property: property, byteCount: string.utf8.count)
            }
        case let .double(double):
            guard double.isFinite else {
                throw AnalyticsWireError.nonFiniteNumber(property: property)
            }
        case .int, .bool:
            break
        }
    }
}

/// A single event in the server analytics request shape.
public struct AnalyticsWireEvent: Encodable, Equatable, Sendable {
    public let name: String
    public let properties: [String: AnalyticsValue]
    public let distinctID: String?
    public let anonymousID: String?
    public let timestamp: Date

    public init(
        name: String,
        properties: [String: AnalyticsValue] = [:],
        distinctID: String? = nil,
        anonymousID: String? = nil,
        timestamp: Date = Date()
    ) {
        self.name = name
        self.properties = properties
        self.distinctID = distinctID
        self.anonymousID = anonymousID
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case event
        case distinctID = "distinct_id"
        case properties
        case timestamp
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .event)
        try container.encodeIfPresent(distinctID, forKey: .distinctID)
        var wireProperties = properties
        if let anonymousID {
            wireProperties["$anon_distinct_id"] = .string(anonymousID)
        }
        try container.encode(wireProperties, forKey: .properties)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

/// A request body for `POST /api/analytics/events`.
public struct AnalyticsWireBatch: Encodable, Equatable, Sendable {
    public let events: [AnalyticsWireEvent]

    public init(events: [AnalyticsWireEvent]) {
        self.events = events
    }

    /// Validates and encodes the body using the server's ISO-8601 timestamp
    /// shape. The request-size bound is checked after encoding, because UTF-8
    /// escaping determines the actual wire size.
    public func encodedData() throws -> Data {
        try AnalyticsWireContract.validate(self)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(WireBody(batch: events))
        guard data.count <= AnalyticsWireContract.maxRequestBytes else {
            throw AnalyticsWireError.requestTooLarge(data.count)
        }
        return data
    }

    private struct WireBody: Encodable {
        let batch: [AnalyticsWireEvent]
    }
}

public enum AnalyticsWireError: Error, Equatable, Sendable {
    case eventNameNotAllowed(String)
    case identifierTooLong(kind: String, byteCount: Int)
    case propertyCountExceeded(Int)
    case stringValueTooLong(property: String, byteCount: Int)
    case nonFiniteNumber(property: String)
    case batchCountExceeded(Int)
    case requestTooLarge(Int)
}
