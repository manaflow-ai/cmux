/// Who asked to disable a task queue (Chrome `TaskQueue::QueueEnabledVoter`,
/// base/task/sequence_manager/task_queue.h). A queue runs only while every voter it made votes
/// enabled; removing a voter takes its vote away.
public struct QueueVoter: Hashable, Sendable {
    fileprivate let id: UInt32
}

/// The votes of one queue's voters.
struct QueueVoterSet {
    private var nextID: UInt32 = 0
    private var voters: Set<UInt32> = []
    private var disabled: Set<UInt32> = []

    /// Whether every voter votes enabled.
    var isEnabled: Bool { disabled.isEmpty }

    /// A new voter, voting enabled.
    mutating func make() -> QueueVoter {
        nextID &+= 1
        voters.insert(nextID)
        return QueueVoter(id: nextID)
    }

    /// Records `voter`'s vote; true when it was the last disabled vote (the queue may run again).
    mutating func set(_ enabled: Bool, by voter: QueueVoter) -> Bool {
        guard voters.contains(voter.id) else { return false }
        guard enabled else {
            disabled.insert(voter.id)
            return false
        }
        return disabled.remove(voter.id) != nil && disabled.isEmpty
    }

    /// Takes `voter`'s vote away, as if it voted enabled; later votes of it are ignored. True when
    /// it was the last disabled vote.
    mutating func remove(_ voter: QueueVoter) -> Bool {
        let wasDisabled = disabled.remove(voter.id) != nil
        voters.remove(voter.id)
        return wasDisabled && disabled.isEmpty
    }
}
