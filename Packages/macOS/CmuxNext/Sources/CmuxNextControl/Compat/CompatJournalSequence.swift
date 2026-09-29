import Synchronization

/// Monotonic sequence for `agent_journal_append` replies.
final class CompatJournalSequence: Sendable {
    private let value = Atomic<UInt64>(0)

    func next() -> UInt64 { value.add(1, ordering: .relaxed).newValue }
}
