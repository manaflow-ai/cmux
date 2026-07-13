public import CMUXMobileCore
public import Foundation

/// One buffered analytics event, ready to be batched and posted.
///
/// Carries the event name, its properties, the merged super-properties captured
/// at enqueue time, the identity context, and a client timestamp. The emitter
/// snapshots super-properties and identity onto each event at enqueue so a later
/// identity change does not retroactively rewrite already-queued events.
public struct AnalyticsEvent: Sendable, Equatable {
    /// The `ios_`-prefixed event name.
    public let name: String
    /// The event-specific properties.
    public let properties: [String: AnalyticsValue]
    /// The current distinct id (user id when identified, else the anonymous id).
    public let distinctID: String?
    /// The anonymous client id, used to alias anonymous→identified server-side.
    public let anonymousID: String?
    /// When the event was recorded on the client.
    public let timestamp: Date

    /// Creates a buffered event.
    public init(
        name: String,
        properties: [String: AnalyticsValue],
        distinctID: String?,
        anonymousID: String?,
        timestamp: Date
    ) {
        self.name = name
        self.properties = properties
        self.distinctID = distinctID
        self.anonymousID = anonymousID
        self.timestamp = timestamp
    }

    /// The event rendered as a JSON-safe dictionary for the capture endpoint.
    ///
    /// Keys mirror the wire contract the web proxy expects: `event`,
    /// `distinct_id`, `properties`, `timestamp` (ISO-8601). The anonymous id is
    /// folded into `properties` as `$anon_distinct_id` when present so the proxy
    /// can alias.
    public var wireObject: [String: any Sendable] {
        var props: [String: any Sendable] = [:]
        for (key, value) in properties {
            props[key] = value.jsonObject
        }
        if let anonymousID {
            props["$anon_distinct_id"] = anonymousID
        }
        return [
            "event": name,
            "distinct_id": distinctID ?? anonymousID ?? "anonymous",
            "properties": props,
            "timestamp": timestamp.ISO8601Format(.iso8601.dateTimeSeparator(.standard)),
        ]
    }
}
