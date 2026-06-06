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

    private enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
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
    }
}
