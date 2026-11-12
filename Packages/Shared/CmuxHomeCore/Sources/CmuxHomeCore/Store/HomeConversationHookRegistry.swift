import Foundation

/// Owns the hooks of the views showing each conversation, held weakly (a
/// view freed without `unregister` hears nothing and is pruned). HomeStore
/// owns one and delivers refusals and unanswered ops through it.
@MainActor
struct HomeConversationHookRegistry {
    private var entries: [ConversationID: [WeakConversationHooks]] = [:]

    /// Adds `hooks` for its conversation; registering it again does nothing.
    mutating func register(_ hooks: HomeConversationHooks) {
        let id = hooks.conversation
        var list = entries[id, default: []].filter { $0.hooks != nil }
        if !list.contains(where: { $0.hooks === hooks }) { list.append(WeakConversationHooks(hooks: hooks)) }
        entries[id] = list
    }

    /// Removes `hooks`; unregistering hooks that are not registered does nothing.
    mutating func unregister(_ hooks: HomeConversationHooks) {
        let id = hooks.conversation
        let list = entries[id, default: []].filter { $0.hooks != nil && $0.hooks !== hooks }
        entries[id] = list.isEmpty ? nil : list
    }

    /// Drops the entries of `conversation` that were freed without `unregister`.
    mutating func prune(_ conversation: ConversationID) {
        let list = entries[conversation, default: []].filter { $0.hooks != nil }
        entries[conversation] = list.isEmpty ? nil : list
    }

    /// The live hooks of the intent's conversation, in registration order.
    /// Taken before any is called, so a hook that unregisters (or registers
    /// another) while it runs changes no delivery of this intent.
    mutating func liveHooks(for intent: HomeIntent) -> [HomeConversationHooks] {
        guard let id = intent.op.conversation else { return [] }
        prune(id)
        return entries[id, default: []].compactMap(\.hooks)
    }

    /// Entries held now, live or freed and not yet pruned (tests).
    var count: Int { entries.values.reduce(0) { $0 + $1.count } }
}
