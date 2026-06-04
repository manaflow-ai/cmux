/// Parameters for `mobile.events.subscribe` requests.
public struct MobileEventsSubscribeParams: Encodable, Sendable {
    /// The client-chosen stream id echoed back on every pushed event.
    public var streamID: String
    /// The event topics to subscribe to.
    public var topics: [String]

    /// Create event-subscribe parameters.
    /// - Parameters:
    ///   - streamID: The client-chosen stream id echoed back on pushed events.
    ///   - topics: The event topics to subscribe to.
    public init(streamID: String, topics: [String]) {
        self.streamID = streamID
        self.topics = topics
    }

    private enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case topics
    }
}
