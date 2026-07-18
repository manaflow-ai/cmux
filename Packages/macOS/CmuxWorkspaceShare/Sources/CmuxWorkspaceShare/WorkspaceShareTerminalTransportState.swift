public import Foundation

/// Coalesces terminal invalidations while an ordered workspace snapshot is sent.
public struct WorkspaceShareTerminalFlushBarrier {
    private var snapshotDepth = 0
    private var pendingSurfaceIDs: Set<UUID> = []

    /// Creates an empty, inactive barrier.
    public init() {}

    /// Blocks pending terminal invalidations from being drained.
    public mutating func beginSnapshot() {
        snapshotDepth += 1
    }

    /// Releases one matching snapshot block.
    public mutating func endSnapshot() {
        precondition(snapshotDepth > 0, "terminal snapshot barrier is unbalanced")
        snapshotDepth -= 1
    }

    /// Coalesces surfaces that need a live terminal refresh.
    public mutating func enqueue(_ surfaceIDs: Set<UUID>) {
        pendingSurfaceIDs.formUnion(surfaceIDs)
    }

    /// Drains pending surfaces only when no snapshot is active.
    public mutating func takePendingIfReady() -> Set<UUID> {
        guard snapshotDepth == 0 else { return [] }
        let result = pendingSurfaceIDs
        pendingSurfaceIDs.removeAll(keepingCapacity: true)
        return result
    }
}

/// Assigns contiguous viewer-facing sequence numbers independently per terminal.
public struct WorkspaceShareTerminalTransportTracker {
    private struct SurfaceState {
        var generation: UInt64
        var stateSeq: UInt64
    }

    private var statesBySurfaceID: [String: SurfaceState] = [:]

    /// Creates a tracker with no known terminal surfaces.
    public init() {}

    /// Whether the next frame must establish a fresh generation.
    public func requiresSnapshot(surfaceId: String) -> Bool {
        guard let state = statesBySurfaceID[surfaceId] else { return true }
        return state.stateSeq >= WorkspaceShareTerminalVTFrame.maximumSafeSequence
    }

    /// Validates an emitted VT payload, assigns its transport stamp, and commits it.
    public mutating func makeFrame(
        surfaceId: String,
        kind: WorkspaceShareTerminalVTFrame.Kind,
        columns: Int,
        rows: Int,
        data: Data
    ) throws -> WorkspaceShareTerminalVTFrame {
        let previous = statesBySurfaceID[surfaceId]
        if kind == .patch,
           previous == nil || previous?.stateSeq == WorkspaceShareTerminalVTFrame.maximumSafeSequence {
            throw WorkspaceShareTerminalVTFrameError.invalidSequence
        }

        let stateSeq = previous.map {
            $0.stateSeq >= WorkspaceShareTerminalVTFrame.maximumSafeSequence ? 1 : $0.stateSeq + 1
        } ?? 1
        let generation: UInt64
        switch kind {
        case .snapshot:
            if let previous {
                generation = previous.generation >= WorkspaceShareTerminalVTFrame.maximumSafeSequence
                    ? 1
                    : previous.generation + 1
            } else {
                generation = 1
            }
        case .patch:
            generation = previous?.generation ?? 0
        }

        let frame = try WorkspaceShareTerminalVTFrame(
            surfaceId: surfaceId,
            generation: generation,
            stateSeq: stateSeq,
            columns: columns,
            rows: rows,
            kind: kind,
            data: data
        )
        statesBySurfaceID[surfaceId] = SurfaceState(generation: generation, stateSeq: stateSeq)
        return frame
    }

    /// Removes counters only for terminal surfaces that no longer exist.
    public mutating func prune(keeping surfaceIDs: Set<String>) {
        statesBySurfaceID = statesBySurfaceID.filter { surfaceIDs.contains($0.key) }
    }
}

struct WorkspaceSharePendingSendBudget {
    static let defaultMaximumMessages = 256
    static let defaultMaximumBytes = 8 * 1_024 * 1_024

    private let maximumMessages: Int
    private let maximumBytes: Int
    private var messageCount = 0
    private var byteCount = 0

    init(
        maximumMessages: Int = Self.defaultMaximumMessages,
        maximumBytes: Int = Self.defaultMaximumBytes
    ) {
        precondition(maximumMessages > 0)
        precondition(maximumBytes > 0)
        self.maximumMessages = maximumMessages
        self.maximumBytes = maximumBytes
    }

    mutating func reserve(byteCount requestedBytes: Int) -> Bool {
        guard requestedBytes > 0,
              requestedBytes <= maximumBytes,
              messageCount < maximumMessages,
              byteCount <= maximumBytes - requestedBytes else { return false }
        messageCount += 1
        byteCount += requestedBytes
        return true
    }

    mutating func release(byteCount releasedBytes: Int) {
        precondition(messageCount > 0)
        precondition(releasedBytes > 0 && releasedBytes <= byteCount)
        messageCount -= 1
        byteCount -= releasedBytes
    }

    mutating func reset() {
        messageCount = 0
        byteCount = 0
    }
}
