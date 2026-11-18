public import Foundation

/// How much of a pane a seed captures.
public enum RemoteTmuxPaneSeedKind: Equatable, Sendable {
    /// The pane's whole history, which replaces its scrollback.
    case fullHistory
    /// The visible screen only.
    case visibleRepaint
}

/// Mutable control-channel state for one pane snapshot transaction: the capture, and the
/// pane's live output on either side of the capture boundary.
public struct RemoteTmuxPendingPaneSeed: Sendable {
    public let id: UUID
    public let kind: RemoteTmuxPaneSeedKind
    /// Live output from before the capture result. The capture already shows it.
    public var discardedOutput: [Data] = []
    public var snapshot: Data
    /// Live output from after the capture result, replayed once after the seed is delivered.
    public var catchUpOutput: [Data] = []
    /// Bytes held in ``discardedOutput`` and ``catchUpOutput``.
    public var bufferedLiveByteCount = 0
    public var isCaptureInstalled = false
    /// Live output before the capture result is dropped instead of retained.
    /// Set by a catch-up after the stream fell behind: that output is stale, the
    /// capture covers it, and retaining it would only run into the live-byte
    /// budget and restart the seed.
    public var dropsPreCaptureOutput = false
    /// Live output is dropped until the seed finishes, not only until its capture. Set when a
    /// visible-only seed joins a catch-up: its capture shows the screen but not the lines the
    /// backlog pushed into history, so a full-history seed behind it repaints the pane, and
    /// everything up to that seed's capture is dropped.
    public var dropsOutputUntilFinished = false
    /// Output before this seed was dropped by a budget recovery without passing through the
    /// live escape filters, so they start over at this seed.
    public var followsDroppedOutput = false

    /// Creates a seed whose snapshot starts as `snapshot`, before any capture arrives.
    public init(
        id: UUID,
        kind: RemoteTmuxPaneSeedKind,
        snapshot: Data,
        dropsPreCaptureOutput: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.snapshot = snapshot
        self.dropsPreCaptureOutput = dropsPreCaptureOutput
    }

    /// Bytes this seed holds against the connection's pending-seed budget.
    public var retainedByteCount: Int {
        snapshot.count + bufferedLiveByteCount
    }

    /// Whether live output arriving now is dropped: the seed belongs to a catch-up and its
    /// capture has not arrived.
    public var dropsLiveOutput: Bool {
        dropsOutputUntilFinished || (dropsPreCaptureOutput && !isCaptureInstalled)
    }

    /// Whether the live escape filters start over when this seed is delivered, because the
    /// output before it was dropped rather than retained.
    public var restartsLiveStream: Bool {
        dropsPreCaptureOutput || followsDroppedOutput
    }

    /// Whether this seed's capture can stand in for a catch-up's own, as the last seed of its
    /// pane: only a full-history capture that has not arrived covers the backlog before it.
    public var coversCatchUp: Bool {
        kind == .fullHistory && !isCaptureInstalled
    }

    /// Whether a catch-up can still take this seed over. Once the capture has arrived, output
    /// still to come is newer than it, so a catch-up needs a capture of its own.
    public var canJoinCatchUp: Bool {
        !isCaptureInstalled
    }

    /// Makes the seed part of a catch-up: drops the output retained before the capture, and any
    /// more until the capture arrives, or until the seed finishes for a visible-only seed, which
    /// leaves the pane's history to a full-history seed behind it. Returns the number of retained
    /// bytes released.
    public mutating func joinCatchUp() -> Int {
        let dropped = discardedOutput.reduce(0) { $0 + $1.count }
        discardedOutput = []
        bufferedLiveByteCount -= dropped
        dropsPreCaptureOutput = true
        if kind != .fullHistory { dropsOutputUntilFinished = true }
        return dropped
    }

    /// Keeps live output on the side of the capture boundary it arrived on. The caller has
    /// already reserved `data.count` bytes of budget for it.
    public mutating func retainLiveOutput(_ data: Data) {
        bufferedLiveByteCount += data.count
        if isCaptureInstalled {
            Self.appendCoalesced(data, to: &catchUpOutput)
        } else {
            Self.appendCoalesced(data, to: &discardedOutput)
        }
    }

    /// Appends to the last chunk, so a long run of small writes is one replay.
    private static func appendCoalesced(_ data: Data, to chunks: inout [Data]) {
        if chunks.isEmpty {
            chunks.append(data)
        } else {
            chunks[chunks.index(before: chunks.endIndex)].append(data)
        }
    }
}
