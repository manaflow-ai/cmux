import Foundation

/// The difference between two parses of the same transcript.
///
/// A live-tailing source reparses the transcript on every file change and uses
/// this to decide which ``ConversationEvent`` to emit: nothing for
/// ``ConversationDelta/unchanged``, an incremental
/// ``ConversationEvent/upsert(_:seq:)`` for
/// ``ConversationDelta/appendedOrChanged(_:)``, and a
/// ``ConversationEvent/truncated`` (followed by a fresh snapshot) for
/// ``ConversationDelta/truncated``.
public enum ConversationDelta: Equatable, Sendable {
    /// The two parses contain identical messages.
    case unchanged

    /// The new parse extends or revises the old one in place: the shared
    /// prefix of message ids is intact, and the associated messages are the
    /// ones that were appended past the old end or whose content changed.
    case appendedOrChanged([Message])

    /// The new parse is not a continuation of the old one (the file shrank or
    /// was rewritten from the start), so prior state must be discarded.
    case truncated

    /// Computes the delta from an older parse to a newer parse.
    ///
    /// Messages are compared positionally: live transcripts are append-mostly,
    /// so id equality along the shared prefix means continuation, while any id
    /// mismatch or a shorter message list means the file was truncated or
    /// rewritten. A message whose id matches but whose content differs (for
    /// example a streaming turn that grew) is included in
    /// ``ConversationDelta/appendedOrChanged(_:)`` so consumers can replace it
    /// by id.
    ///
    /// - Parameters:
    ///   - old: The previously parsed conversation.
    ///   - new: The freshly parsed conversation.
    /// - Returns: The delta to emit.
    public static func compute(from old: Conversation, to new: Conversation) -> ConversationDelta {
        guard new.messages.count >= old.messages.count else { return .truncated }

        var changed: [Message] = []
        for (index, oldMessage) in old.messages.enumerated() {
            let newMessage = new.messages[index]
            guard newMessage.id == oldMessage.id else { return .truncated }
            if newMessage != oldMessage {
                changed.append(newMessage)
            }
        }
        changed.append(contentsOf: new.messages[old.messages.count...])
        return changed.isEmpty ? .unchanged : .appendedOrChanged(changed)
    }
}
