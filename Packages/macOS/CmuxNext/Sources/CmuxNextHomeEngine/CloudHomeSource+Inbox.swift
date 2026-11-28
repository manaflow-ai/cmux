import CmuxHomeCore
import CmuxNextDaemon
import Foundation

nonisolated extension CloudHomeSource {
    // MARK: Inbox

    func reloadInbox(generation: UInt64) async {
        guard state.withLock({ $0.generation == generation }), let inbox = try? await inbox() else { return }
        publish(generation: generation) { _ in .inbox(inbox) }
    }

    func publishInbox() {
        publish { state in .inbox(state.snapshot(me: me)) }
    }

    /// Queues a one-message snapshot read for each listed conversation
    /// without a current head and publishes its summary. One queue serves
    /// the whole source, so at most `hydrationWidth` reads use the daemon's
    /// request budget at once, and a conversation waits in it only once.
    func hydrate(_ ids: [ConversationID], generation: UInt64) {
        let (commands, identity, workers) = state.withLock { state -> ((any CloudConversationCommands)?, CloudIdentity?, Int) in
            guard state.generation == generation, let commands = state.commands, let identity = state.identity else { return (nil, nil, 0) }
            let fresh = ids.filter { !state.hydrating.contains($0) }
            state.hydrating.formUnion(fresh)
            state.hydrationQueue.append(contentsOf: fresh)
            let workers = min(Self.hydrationWidth - state.hydrationWorkers, state.hydrationQueue.count)
            guard workers > 0 else { return (nil, nil, 0) }
            state.hydrationWorkers += workers
            return (commands, identity, workers)
        }
        guard let commands, let identity else { return }
        for _ in 0..<workers {
            // task-owner: one hydration worker; ends when the queue is empty or the account or connection changes
            Task { [weak self] in
                while let id = self?.nextHydration(generation: generation) {
                    await self?.hydrateOne(id, commands: commands, identity: identity, generation: generation)
                }
            }
        }
    }

    /// The next queued conversation for a worker, or nil when it ends.
    private func nextHydration(generation: UInt64) -> ConversationID? {
        state.withLock { state in
            // A configure since reset the queue and the worker count.
            guard state.generation == generation else { return nil }
            guard !state.hydrationQueue.isEmpty else {
                state.hydrationWorkers -= 1
                return nil
            }
            return state.hydrationQueue.removeFirst()
        }
    }

    private func hydrateOne(_ id: ConversationID, commands: any CloudConversationCommands, identity: CloudIdentity,
                            generation: UInt64) async {
        let page = try? await commands.snapshot(id.rawValue, tail: 1)
        publish(generation: generation) { state in
            state.hydrating.remove(id)
            guard let page, state.entries[id] != nil else { return nil }
            let summary = CloudHomeMapping.summary(page.conversation, identity: identity)
            if let known = state.heads[id], known.rev >= summary.rev { return nil }
            state.heads[id] = summary
            state.inboxRev += 1
            return state.joined(id).map { .conversationChanged($0, stream: .inbox, rev: state.inboxRev) }
        }
    }

    /// An inbox list's revision as the inbox stream seq (UserDO sends
    /// `String(currentSeq)`); nil when it is not one.
    static func revision(_ value: JSONValue?) -> UInt64? {
        switch value {
        case .string(let text): UInt64(text)
        case .number(let number) where number >= 0 && number < 1.8e19 && number.rounded() == number: UInt64(number)
        default: nil
        }
    }
}
