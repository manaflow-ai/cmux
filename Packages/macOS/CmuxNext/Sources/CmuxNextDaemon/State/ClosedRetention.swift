import CmuxNextIPC

/// `history.closed.maxGroups` and `history.closed.maxAgeDays` applied to one
/// daemon's closed history (reopen-closed.md S1b). The daemon stores no
/// limit: the app compares its mirror with the limits and, when the history
/// is over one, sends `closed.delete {all, keep_newest, before_ms}`.
public struct ClosedRetention: Sendable, Equatable {
    /// Groups to keep; 0 keeps every group.
    public var maxGroups: Int
    /// Days to keep a group; 0 keeps groups of any age.
    public var maxAgeDays: Int

    public init(maxGroups: Int, maxAgeDays: Int) {
        self.maxGroups = maxGroups
        self.maxAgeDays = maxAgeDays
    }

    /// What one `closed.delete` deletes: groups closed before `beforeMs`,
    /// and every group but the newest `keepNewest`.
    public struct Prune: Sendable, Equatable {
        public var beforeMs: UInt64?
        public var keepNewest: Int?
    }

    /// The prune that brings `items` (a mirror's closed items, one per
    /// group, newest `SessionStateMirror.closedLimit` at most) within the
    /// limits at `nowMs`, nil when they already are. A full mirror may lack
    /// older groups, so with a limit set it always asks; the daemon then
    /// deletes only what is over.
    public func prune(_ items: [ClosedItem], nowMs: UInt64) -> Prune? {
        let full = items.count >= SessionStateMirror.closedLimit
        var prune = Prune()
        if maxGroups > 0, full || items.count > maxGroups { prune.keepNewest = maxGroups }
        if maxAgeDays > 0 {
            // An age too large for UInt64 milliseconds keeps everything, like a cutoff before 1970.
            let age = UInt64(clamping: maxAgeDays).multipliedReportingOverflow(by: 86_400_000)
            let cutoff = nowMs.subtractingReportingOverflow(age.partialValue)
            if !age.overflow, !cutoff.overflow, full || items.contains(where: { $0.closedAtMs < cutoff.partialValue }) {
                prune.beforeMs = cutoff.partialValue
            }
        }
        return prune == Prune() ? nil : prune
    }
}

extension StateResourceClient {
    /// Applies a retention prune (`closed.delete {all, before_ms, keep_newest}`).
    public func pruneClosed(_ prune: ClosedRetention.Prune) async throws {
        try await stateMutation(Self.pruneRequest(prune))
    }

    /// The `closed.delete {all, before_ms?, keep_newest?}` request of `prune`.
    static func pruneRequest(_ prune: ClosedRetention.Prune) -> V2ClosedDeleteRequest {
        V2ClosedDeleteRequest(all: true, beforeMs: prune.beforeMs.map { String($0) },
                              keepNewest: prune.keepNewest.map { UInt32(clamping: $0) })
    }
}
