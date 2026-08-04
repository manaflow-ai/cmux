public import Foundation

/// Typed response for the read-only `mobile.events.probe` RPC.
public struct MobileEventProbeResponse: Decodable, Equatable, Sendable {
    /// Event stream identifier inspected by the host.
    public let streamID: String
    /// Whether that stream is currently registered on this connection.
    public let subscribed: Bool
    /// Current event delivery transport, when reported by the host.
    public let eventTransport: String?

    private enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case subscribed
        case eventTransport = "event_transport"
    }

    /// Creates a probe response for a host-side registration lookup.
    public init(
        streamID: String,
        subscribed: Bool,
        eventTransport: String?
    ) {
        self.streamID = streamID
        self.subscribed = subscribed
        self.eventTransport = eventTransport
    }

    /// JSON object used by the host's existing response-envelope encoder.
    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "stream_id": streamID,
            "subscribed": subscribed,
        ]
        if let eventTransport {
            object["event_transport"] = eventTransport
        }
        return object
    }

    /// Decodes one probe result payload received by a mobile client.
    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
