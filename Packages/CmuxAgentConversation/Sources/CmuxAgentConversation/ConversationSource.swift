import Foundation

/// A source of conversation state and updates.
///
/// A view model subscribes to ``ConversationSource/events`` and projects each
/// emission for rendering, and can pull the current state on demand via
/// ``ConversationSource/snapshot()``. P1 implements this as a one-shot local
/// file read that yields a single ``ConversationEvent/snapshot(_:)`` and
/// finishes; P3 adds a live-tailing implementation behind the same protocol.
public protocol ConversationSource: Sendable {
    /// The stream of conversation updates. The first element is the initial
    /// snapshot; the stream finishes when no further updates will arrive.
    var events: AsyncStream<ConversationEvent> { get }

    /// Returns the current conversation state.
    ///
    /// - Returns: The latest parsed conversation.
    func snapshot() async -> Conversation
}
