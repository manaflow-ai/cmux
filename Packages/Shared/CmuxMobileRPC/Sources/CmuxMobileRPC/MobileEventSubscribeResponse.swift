public import Foundation

/// Typed decoder for the `mobile.events.subscribe` RPC result.
///
/// The Mac acknowledges a subscription by echoing back the `stream_id` it
/// registered. A non-empty `stream_id` is the success signal the listener loop
/// keys off; an absent or empty value means the subscription did not take.
public struct MobileEventSubscribeResponse: Decodable, Sendable {
    /// The server-registered event stream identifier.
    ///
    /// Empty or missing when the subscription was not accepted.
    public let streamID: String

    /// Whether the host already had a registration for this `stream_id` on
    /// this connection before processing the request (`mobile.events.subscribe`
    /// is idempotent per stream id).
    ///
    /// `false` means this acknowledgement INSTALLED the registration, so any
    /// events emitted while it was absent were never delivered; the liveness
    /// probe uses that to trigger a catch-up replay. `nil` when the host
    /// predates the field, which callers must treat as "unknown, assume it was
    /// already active" so older Macs keep today's behavior.
    public let alreadySubscribed: Bool?

    /// The selected event delivery path, absent on older hosts.
    public let eventTransport: String?

    private enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case alreadySubscribed = "already_subscribed"
        case eventTransport = "event_transport"
    }

    /// Decode a subscribe acknowledgement from raw JSON data.
    ///
    /// Tolerant of a missing `stream_id` (decodes to an empty string) so a
    /// malformed acknowledgement is treated as "not subscribed" rather than a
    /// thrown error the caller would have to special-case.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded acknowledgement.
    /// - Throws: A decoding error only if the payload is not a JSON object.
    public static func decode(_ data: Data) throws -> MobileEventSubscribeResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamID = (try container.decodeIfPresent(String.self, forKey: .streamID)) ?? ""
        alreadySubscribed = try container.decodeIfPresent(Bool.self, forKey: .alreadySubscribed)
        eventTransport = try container.decodeIfPresent(String.self, forKey: .eventTransport)
    }
}
