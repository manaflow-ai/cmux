public import Foundation

/// Where a reader was in a conversation: the newest visible message and its
/// offset from the bottom of the viewport, in points. A message newer than
/// `message` scrolls to the bottom instead.
public struct HomeScrollAnchor: Hashable, Sendable, Codable {
    public var message: MessageID
    public var offset: Double

    public init(message: MessageID, offset: Double) {
        self.message = message
        self.offset = offset
    }
}
