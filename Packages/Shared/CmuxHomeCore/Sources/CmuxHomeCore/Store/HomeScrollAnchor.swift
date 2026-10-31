public import Foundation

/// Where a reader was in a conversation: the newest visible message and how
/// far its bottom sat above the bottom of the viewport, in points. None means
/// the newest message, where a conversation opens (#27627); so does an anchor
/// whose message is not loaded when the conversation opens.
public struct HomeScrollAnchor: Hashable, Sendable, Codable {
    public var message: MessageID
    public var offset: Double

    public init(message: MessageID, offset: Double) {
        self.message = message
        self.offset = offset
    }
}
