public import Foundation

/// One decoded or encoded media frame handed to a sink.
public struct MediaFrame: Sendable {
    public enum Payload: Sendable {
        /// Encoded bytes (test carriers, encoded passthrough).
        case encoded(Data)
        /// A platform buffer (for example a pixel buffer) the carrier wraps.
        case native(any Sendable)
    }

    public var timestamp: Duration
    public var width: Int
    public var height: Int
    public var payload: Payload

    public init(timestamp: Duration, width: Int, height: Int, payload: Payload) {
        self.timestamp = timestamp
        self.width = width
        self.height = height
        self.payload = payload
    }
}
