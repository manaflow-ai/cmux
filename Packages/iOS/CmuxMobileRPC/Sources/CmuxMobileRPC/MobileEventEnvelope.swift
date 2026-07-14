public import Foundation

/// One server-pushed event delivered over the persistent transport.
public struct MobileEventEnvelope: Sendable {
    /// The event topic (matches a subscription topic).
    public let topic: String
    /// The event payload as raw JSON, if present.
    public let payloadJSON: Data?
    /// The associated stream identifier, if the event carries one.
    public let streamID: String?
    /// The surface identifier extracted while the event envelope is parsed.
    /// This lets consumers establish per-surface ordering before decoding a
    /// potentially large payload away from the UI actor.
    public let surfaceID: String?

    /// Creates an event envelope.
    /// - Parameters:
    ///   - topic: The event topic.
    ///   - payloadJSON: The raw JSON payload, if any.
    ///   - streamID: The associated stream identifier, if any.
    ///   - surfaceID: The routed terminal surface, if the payload carries one.
    public init(topic: String, payloadJSON: Data?, streamID: String?, surfaceID: String? = nil) {
        self.topic = topic
        self.payloadJSON = payloadJSON
        self.streamID = streamID
        self.surfaceID = surfaceID
    }
}

extension MobileEventEnvelope {
    static func parsing(topic: String, payload: Any?, streamID: String?) -> Self {
        let payloadJSON = payload.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let payloadObject = payload as? [String: Any]
        let renderGridObject = payloadObject?["render_grid"] as? [String: Any]
        let surfaceID = (payloadObject?["surface_id"] as? String)
            ?? (renderGridObject?["surface_id"] as? String)
        return Self(
            topic: topic,
            payloadJSON: payloadJSON,
            streamID: streamID,
            surfaceID: surfaceID
        )
    }
}
