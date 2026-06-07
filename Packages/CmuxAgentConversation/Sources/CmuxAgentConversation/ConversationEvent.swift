import Foundation

/// An update emitted by a ``ConversationSource``.
///
/// P1 only ever emits a single ``ConversationEvent/snapshot(_:)``. The
/// incremental cases exist so a later live-tailing or mobile-stream source can
/// push deltas without changing the consumer's event shape.
public enum ConversationEvent: Sendable {
    /// A full replacement of the current conversation state.
    case snapshot(Conversation)

    /// New or changed messages, tagged with the producing conversation's `seq`
    /// so consumers can order and merge them.
    case upsert([Message], seq: UInt64)

    /// The underlying transcript was truncated or rewritten from the start;
    /// consumers should discard prior state and await a fresh snapshot.
    case truncated
}
