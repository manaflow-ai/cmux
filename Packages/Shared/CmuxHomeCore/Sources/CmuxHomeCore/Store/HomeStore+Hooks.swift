import Foundation

// HomeStore's conversation hooks: the views that hear refusals and
// unanswered ops for a conversation.
extension HomeStore {
    // MARK: Conversation hooks

    /// A view of `hooks.conversation` hears that conversation's refusals and
    /// unanswered ops nobody awaits until `unregister`, or until it is freed
    /// (the store holds it weakly). Registering it again does nothing.
    public func register(_ hooks: HomeConversationHooks) {
        let id = hooks.conversation
        var list = self.hooks[id, default: []].filter { $0.hooks != nil }
        if !list.contains(where: { $0.hooks === hooks }) { list.append(WeakConversationHooks(hooks: hooks)) }
        self.hooks[id] = list
    }

    /// The view stopped: it hears nothing more. Unregistering hooks that are
    /// not registered does nothing.
    public func unregister(_ hooks: HomeConversationHooks) {
        let id = hooks.conversation
        let list = self.hooks[id, default: []].filter { $0.hooks != nil && $0.hooks !== hooks }
        self.hooks[id] = list.isEmpty ? nil : list
    }

    /// Drops the entries of `conversation`'s hooks that were freed without
    /// `unregister` (a binding's deinit calls it).
    public func pruneHooks(for conversation: ConversationID) {
        let list = hooks[conversation, default: []].filter { $0.hooks != nil }
        hooks[conversation] = list.isEmpty ? nil : list
    }

    /// The live hooks of the intent's conversation, in registration order.
    /// Taken before any is called, so a hook that unregisters (or registers
    /// another) while it runs changes no delivery of this intent.
    private func liveHooks(for intent: HomeIntent) -> [HomeConversationHooks] {
        guard let id = intent.op.conversation else { return [] }
        pruneHooks(for: id)
        return hooks[id, default: []].compactMap(\.hooks)
    }

    /// A refusal nobody awaits: each live view of its conversation hears it
    /// once; with none, `onRefusal` does.
    func reportRefusal(_ intent: HomeIntent, _ rejection: HomeRejection) {
        let live = liveHooks(for: intent)
        guard !live.isEmpty else { onRefusal?(intent, rejection); return }
        for hooks in live { hooks.onRefusal(intent, rejection) }
    }

    /// An op that ran out of resends: each live view of its conversation
    /// hears it once; with none, `onUnanswered` does.
    func reportUnanswered(_ intent: HomeIntent) {
        let live = liveHooks(for: intent)
        guard !live.isEmpty else { onUnanswered?(intent); return }
        for hooks in live { hooks.onUnanswered(intent) }
    }

    /// Hook entries the store holds now, live or freed and not yet pruned (tests).
    var registeredHookCount: Int { hooks.values.reduce(0) { $0 + $1.count } }
}
