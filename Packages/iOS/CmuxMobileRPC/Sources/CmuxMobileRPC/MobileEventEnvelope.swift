public import Foundation
internal import CMUXMobileCore

/// One server-pushed event delivered over the persistent transport.
public struct MobileEventEnvelope: Sendable {
    /// The event topic (matches a subscription topic).
    public let topic: String
    /// The event payload as raw JSON, if present.
    public let payloadJSON: Data?
    /// The associated stream identifier, if the event carries one.
    public let streamID: String?

    /// Creates an event envelope.
    /// - Parameters:
    ///   - topic: The event topic.
    ///   - payloadJSON: The raw JSON payload, if any.
    ///   - streamID: The associated stream identifier, if any.
    public init(topic: String, payloadJSON: Data?, streamID: String?) {
        self.topic = topic
        self.payloadJSON = payloadJSON
        self.streamID = streamID
    }
}

extension MobileEventEnvelope {
    /// A render-grid event recognized by its fixed envelope bytes, with the
    /// frame sliced out unparsed; nil for every other event.
    static func splicedRenderGridEvent(_ frame: Data) -> MobileEventEnvelope? {
        guard let payload = MobileRenderGridEventSplice.payloadJSON(of: frame) else { return nil }
        return MobileEventEnvelope(
            topic: MobileRenderGridEventSplice.topic,
            payloadJSON: payload,
            streamID: nil
        )
    }
}
