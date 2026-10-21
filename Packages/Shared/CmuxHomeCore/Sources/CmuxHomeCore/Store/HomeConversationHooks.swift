/// What one view of a conversation hears from the store that no call it
/// made awaits: a refusal of a resumed upload or a resend, and an op that
/// ran out of resends unanswered. A view registers its hooks with
/// `HomeStore.register(_:)` and unregisters them when it stops;
/// `HomeStoreBinding` does both. Every live view of the conversation hears
/// each intent once (two Mac tabs of it both show the notice); with no view
/// registered, the store's own `onRefusal` and `onUnanswered` hear it.
@MainActor
public final class HomeConversationHooks {
    public let conversation: ConversationID
    public var onRefusal: (HomeIntent, HomeRejection) -> Void
    public var onUnanswered: (HomeIntent) -> Void

    public init(conversation: ConversationID, onRefusal: @escaping (HomeIntent, HomeRejection) -> Void = { _, _ in },
                onUnanswered: @escaping (HomeIntent) -> Void = { _ in }) {
        self.conversation = conversation
        self.onRefusal = onRefusal
        self.onUnanswered = onUnanswered
    }
}

/// The store's weak reference to registered hooks.
@MainActor
struct WeakConversationHooks {
    weak var hooks: HomeConversationHooks?
}
