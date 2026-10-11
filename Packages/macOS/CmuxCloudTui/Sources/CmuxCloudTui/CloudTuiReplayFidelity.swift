import Foundation

/// Tracks whether the local terminal holds the daemon's latest replacement
/// replay at the grid it was authored for.
///
/// A `vt-state` or `resized` replay addresses rows by absolute cursor position
/// on the daemon's grid. Parsed into a smaller local grid, those rows clamp
/// onto each other, and growing the pane back to the daemon's grid cannot
/// restore them: the daemon acknowledges an unchanged size without replaying.
/// A hidden restore parses its replay at the bootstrap grid, so the revealed
/// pane keeps the clamped rows. This state machine names the replays that were
/// not parsed at their grid, so the session can refetch one once the local
/// grid matches, a bounded number of times.
public struct CloudTuiReplayFidelity: Equatable, Sendable {
    /// The daemon grid the latest replay was authored for.
    public private(set) var remoteGrid: CloudTuiManualIOGrid?
    /// The grid holding a faithful copy of the latest replay, or nil when it
    /// was parsed at another grid or the local grid has changed since.
    public private(set) var faithfulGrid: CloudTuiManualIOGrid?
    /// Refetches since the last faithful replay.
    public private(set) var repairs = 0
    public let repairLimit: Int
    private var generation: UInt64 = 0
    /// Changes with terminal dimensions, including an away-and-back change
    /// that returns to the same dimensions before replay parsing ends.
    /// The replay lane is asynchronous, so dimensions alone cannot establish
    /// that the bytes were parsed without an intervening resize.
    private var localGridEpoch: UInt64 = 0
    private var observedLocalGrid: CloudTuiManualIOGrid?
    private var queuedGrid: CloudTuiManualIOGrid?
    private var queuedLocalGridEpoch: UInt64?
    private var replayParsePending = false

    public init(repairLimit: Int = 2) {
        self.repairLimit = repairLimit
    }

    /// Records a replay for `remote` about to be parsed while the terminal
    /// holds `local` (nil while a local resize is still pending). Returns the
    /// token its parse completion reports back.
    public mutating func replayQueued(
        remote: CloudTuiManualIOGrid?,
        local: CloudTuiManualIOGrid?
    ) -> UInt64 {
        localGridChanged(to: local)
        generation &+= 1
        remoteGrid = remote
        faithfulGrid = nil
        queuedGrid = remote != nil && local == remote ? local : nil
        queuedLocalGridEpoch = localGridEpoch
        replayParsePending = true
        return generation
    }

    /// Records that the parser applied replay `token` and the terminal still
    /// holds `local`. The replay is faithful when the grid matched the
    /// daemon's on both sides of the parse.
    public mutating func replayApplied(token: UInt64, local: CloudTuiManualIOGrid?) {
        guard token == generation,
              let queuedGrid,
              local == queuedGrid,
              queuedLocalGridEpoch == localGridEpoch
        else {
            if token == generation { replayParsePending = false }
            return
        }
        replayParsePending = false
        faithfulGrid = queuedGrid
        repairs = 0
    }

    /// Records that the replacement bytes were discarded before parsing (for
    /// example, because the bounded pre-runtime output buffer overflowed).
    /// The replay remains unfaithful and may be refetched once the local grid
    /// is usable.
    public mutating func replayDiscarded(token: UInt64) {
        guard token == generation else { return }
        replayParsePending = false
        faithfulGrid = nil
    }

    /// A local resize after a faithful parse moves or clamps its rows.
    public mutating func localGridChanged(to grid: CloudTuiManualIOGrid?) {
        guard grid != observedLocalGrid else { return }
        observedLocalGrid = grid
        localGridEpoch &+= 1
        if grid != faithfulGrid { faithfulGrid = nil }
    }

    /// Whether a check could still decide to refetch.
    public var mayNeedRepair: Bool {
        remoteGrid != nil && faithfulGrid == nil && repairs < repairLimit && !replayParsePending
    }

    /// Whether refetching now would replace an unfaithful replay with a
    /// faithful one: the terminal holds the daemon's grid and budget remains.
    public func needsRepair(local: CloudTuiManualIOGrid?) -> Bool {
        mayNeedRepair && local == remoteGrid
    }

    /// Spends one refetch. The budget refills on the next faithful replay.
    public mutating func repairStarted() {
        repairs += 1
    }
}
