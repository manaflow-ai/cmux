public import Foundation

/// A raw server-pushed `gui.v1` event delivered by an ``AgentSyncTransport``.
public struct AgentSyncFrame: Hashable, Sendable {
    /// The subscribed event topic that carried the payload.
    public let topic: String
    /// The raw JSON payload for the `gui.v1` frame.
    public let payload: Data

    /// Creates a sync frame.
    /// - Parameters:
    ///   - topic: The subscribed event topic.
    ///   - payload: The raw JSON frame payload.
    public init(topic: String, payload: Data) {
        self.topic = topic
        self.payload = payload
    }
}
