import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

nonisolated extension CloudHomeSource {
    // MARK: Edit echo

    /// An edit of `conversation` starts: a deadline waiting for an earlier
    /// edit's echo waits for this one's op too.
    func beginEdit(_ conversation: ConversationID, generation: UInt64) {
        state.withLock { state in
            guard state.generation == generation else { return }
            var hold = state.editHolds[conversation]
                ?? CloudHomeState.EditHold(deadline: DemandTimer(owner: "App.homeCloud.editEcho", clock: clock))
            hold.inFlight += 1
            hold.deadline.cancel()
            state.editHolds[conversation] = hold
        }
    }

    /// An edit's op answered (`committedAt`: its revision) or was refused
    /// (`final`: the store never resends it). Once no edit of the
    /// conversation is in flight, the subscription ends when the newest
    /// committed edit's echo has arrived, or at once when nothing waits for
    /// one; otherwise at the echo or at `editEchoDeadline`, whichever comes
    /// first. A transcript that shows the conversation keeps its own.
    func finishEdit(_ conversation: ConversationID, generation: UInt64, committedAt rev: UInt64?, final: Bool) {
        state.withLock { state in
            guard state.generation == generation, var hold = state.editHolds[conversation] else { return }
            hold.inFlight = max(hold.inFlight - 1, 0)
            if let rev { hold.awaited = max(hold.awaited ?? 0, rev) }
            state.editHolds[conversation] = hold
            guard hold.inFlight == 0 else { return }
            if state.viewed.contains(conversation) {
                state.editHolds[conversation] = nil
                return
            }
            let echoed = hold.awaited.map { hold.seen >= $0 } ?? final
            if echoed {
                state.endEditSubscription(conversation)
                return
            }
            hold.deadline.schedule(after: Self.editEchoDeadline) { [weak self] in
                self?.editDeadlinePassed(conversation, generation: generation)
            }
        }
    }

    /// A conversation event at `rev`: the echo of a held edit ends its subscription.
    func echoed(_ conversation: ConversationID, rev: UInt64) {
        state.withLock { state in
            guard var hold = state.editHolds[conversation] else { return }
            hold.seen = max(hold.seen, rev)
            state.editHolds[conversation] = hold
            guard hold.inFlight == 0, let awaited = hold.awaited, hold.seen >= awaited else { return }
            state.endEditSubscription(conversation)
        }
    }

    private func editDeadlinePassed(_ conversation: ConversationID, generation: UInt64) {
        state.withLock { state in
            // An edit in flight arms the deadline again when it answers.
            guard state.generation == generation, state.editHolds[conversation]?.inFlight == 0 else { return }
            state.endEditSubscription(conversation)
        }
    }
}
