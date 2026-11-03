import Foundation

/// What Messages' Forward button hands to New Message: the messages picked in
/// select mode ("More…"), in transcript order. A compose sheet prefills its
/// draft from `messages` (text via `draftText`, photos via `attachments`).
public struct ConversationForwardDraft: Sendable, Hashable {
    /// Selected messages, oldest first. Unsent messages are left out; they
    /// have no content to forward.
    public var messages: [ConversationMessage]

    public init(messages: [ConversationMessage]) {
        self.messages = messages.filter { !$0.isUnsent }
    }

    /// Picks `selectedIDs` out of a transcript, keeping transcript order (the
    /// order a person tapped the circles in does not matter, as in Messages).
    public init(transcript: [ConversationMessage], selectedIDs: Set<String>) {
        self.init(messages: transcript.filter { selectedIDs.contains($0.id) })
    }

    public var isEmpty: Bool { messages.isEmpty }

    /// The forwarded texts, one message per line, for the compose field.
    public var draftText: String {
        messages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Every attachment of the forwarded messages, in order.
    public var attachments: [ConversationAttachment] {
        messages.flatMap(\.attachments)
    }
}
