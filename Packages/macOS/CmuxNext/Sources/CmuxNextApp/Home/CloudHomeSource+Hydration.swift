import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Synchronization

extension CloudHomeSource {
    fileprivate func hydrate(_ ids: [ConversationID], generation: UInt64) {
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
    fileprivate func nextHydration(generation: UInt64) -> ConversationID? {
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

    fileprivate func hydrateOne(_ id: ConversationID, commands: any CloudConversationCommands, identity: CloudIdentity,
                            generation: UInt64) async {
        let page = try? await commands.snapshot(id.rawValue, tail: 1)
        publish(generation: generation) { state in
            state.hydrating.remove(id)
            guard let page, state.entries[id] != nil else { return nil }
            let summary = CloudHomeMapping.summary(page.conversation, identity: identity)
            if let known = state.heads[id], known.rev >= summary.rev { return nil }
            state.heads[id] = summary
            state.inboxRev += 1
            return joined(id, state).map { .conversationChanged($0, stream: .inbox, rev: state.inboxRev) }
        }
    }

    // MARK: State helpers (call with the lock held)

    /// The listed conversations, the ones this source created and not yet
    /// listed, and the open ones: a conversation the user opened (subscribed,
    /// from a deep link, a notification or the archive) stays while it is
    /// on screen, unless UserDO took it out of the inbox since. It leaves
    /// when its subscription ends (its transcript closed, the least recently
    /// used of 64, a closed socket, or an account change).
}
