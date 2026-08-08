import Foundation

/// Stores at most one reply and decides when it may leave the parking lane.
struct PendingReplyState: Sendable {
    static let lifetime: TimeInterval = 120

    private(set) var pending: PendingReply?

    /// Replaces any older parked reply so the most recent user intent wins.
    mutating func park(_ reply: PendingReply) {
        pending = reply
    }

    /// Drops the current reply when topology proves it can no longer be delivered safely.
    mutating func discard() {
        pending = nil
    }

    /// Evaluates expiry and all prerequisites without depending on UIKit or a live shell store.
    mutating func evaluate(
        now: Date,
        isStoreBound: Bool,
        isTargetReachable: Bool,
        isChannelAvailable: Bool
    ) -> PendingReplyDecision {
        guard let pending else { return .noPending }
        guard now.timeIntervalSince(pending.createdAt) < Self.lifetime else {
            self.pending = nil
            return .expired
        }
        guard isStoreBound, isTargetReachable, isChannelAvailable else {
            return .waiting
        }
        self.pending = nil
        return .ready(pending)
    }
}
