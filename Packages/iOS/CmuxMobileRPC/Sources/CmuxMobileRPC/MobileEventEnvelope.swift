public import Foundation
public import CMUXMobileCore

/// One server-pushed event delivered over the persistent transport.
public struct MobileEventEnvelope: Sendable {
    /// The event topic (matches a subscription topic).
    public let topic: String
    /// The event payload as raw JSON, if present.
    public let payloadJSON: Data?
    /// The associated stream identifier, if the event carries one.
    public let streamID: String?
    /// A render-grid frame already decoded from its binary wire form by the
    /// session actor, so the main actor never parses frame bytes.
    public let renderGrid: MobileTerminalRenderGridFrame?

    /// Creates an event envelope.
    /// - Parameters:
    ///   - topic: The event topic.
    ///   - payloadJSON: The raw JSON payload, if any.
    ///   - streamID: The associated stream identifier, if any.
    public init(topic: String, payloadJSON: Data?, streamID: String?) {
        self.topic = topic
        self.payloadJSON = payloadJSON
        self.streamID = streamID
        self.renderGrid = nil
    }

    /// A `terminal.render_grid` event carrying a decoded frame.
    public init(renderGrid: MobileTerminalRenderGridFrame) {
        self.topic = MobileTerminalRenderGridFrame.eventTopic
        self.payloadJSON = nil
        self.streamID = nil
        self.renderGrid = renderGrid
    }
}

