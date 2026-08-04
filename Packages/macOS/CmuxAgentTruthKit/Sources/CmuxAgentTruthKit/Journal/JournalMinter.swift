public import CmuxAgentReplica
import Foundation

/// Decides whether successive transcript identities reuse or mint journal ids.
public struct JournalMinter: Sendable {
    private var generation: UInt64

    /// Creates a journal minter.
    public init() {
        self.generation = 0
    }

    /// Decides whether a new transcript identity should reuse the current journal.
    /// - Parameters:
    ///   - previous: The prior transcript identity, when one exists.
    ///   - current: The current transcript identity.
    ///   - currentJournalID: The existing journal id, when one exists.
    /// - Returns: A same-or-new journal decision.
    public mutating func decide(
        previous: JournalIdentity?,
        current: JournalIdentity,
        currentJournalID: JournalID?
    ) -> JournalDecision {
        guard let previous, let currentJournalID else {
            return .created(mint(for: current))
        }
        if previous == current {
            return .same(currentJournalID)
        }
        return .created(mint(for: current))
    }

    private mutating func mint(for _: JournalIdentity) -> JournalID {
        generation += 1
        return JournalID(rawValue: "journal:\(generation)")
    }
}
