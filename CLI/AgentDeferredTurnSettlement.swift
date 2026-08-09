import Foundation

/// A provisional agent turn boundary waiting for structured work to drain.
struct AgentDeferredTurnSettlement: Codable, Equatable, Sendable {
    let id: UUID
    let turnId: String?
    let workspaceId: String?
    let surfaceId: String?
    let transcriptPath: String?
    let lastAssistantMessage: String?
    /// Durable single-owner replay claim. Optional fields preserve decoding of
    /// state written before overlapping hook replay was serialized.
    var replayClaimID: UUID? = nil
    var replayClaimedAt: TimeInterval? = nil

    /// Returns an exact replay claim unless an existing owner still holds the lease.
    func claimingReplay(
        at now: TimeInterval,
        leaseDuration: TimeInterval,
        claimID: UUID
    ) -> Self? {
        let hasLiveClaim = replayClaimID != nil
            && replayClaimedAt.map {
                $0 > now - leaseDuration
            } == true
        guard !hasLiveClaim else { return nil }

        var claimed = self
        claimed.replayClaimID = claimID
        claimed.replayClaimedAt = now
        return claimed
    }

    /// Releases only the exact claim that still owns this settlement payload.
    func releasingReplayClaim(matching claimedSettlement: Self) -> Self? {
        guard claimedSettlement.replayClaimID != nil,
              self == claimedSettlement else {
            return nil
        }

        var released = self
        released.replayClaimID = nil
        released.replayClaimedAt = nil
        return released
    }
}
