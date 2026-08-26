import Foundation

/// Pure per-subscription flow-control and settle-frame state.
public struct MobileBrowserStreamPacing: Equatable, Sendable {
    /// Maximum frames allowed to await acknowledgement.
    public let maximumUnackedFrames: Int
    /// Minimum interval between emitted frames.
    public let minimumFrameInterval: TimeInterval
    /// Quiet interval before a lossless settle frame.
    public let settleDelay: TimeInterval
    /// Interval a full unacked window may stall before it is treated as lost.
    public let ackStallTimeout: TimeInterval
    /// Most recently allocated sequence, or zero before the first frame.
    public private(set) var lastSequence: UInt64 = 0
    /// Sequences still awaiting cumulative acknowledgement.
    public private(set) var unackedSequences: [UInt64] = []

    private var dirtyGeneration: UInt64 = 0
    private var hasDirtyFrame = false
    private var settleFramePending = false
    private var reconcileFramePending = false
    private var lastDirtyAt: TimeInterval?
    private var lastEmissionAt: TimeInterval?
    private var windowFullSince: TimeInterval?

    /// Creates pacing state for a new subscription.
    public init(
        maximumUnackedFrames: Int = 3,
        minimumFrameInterval: TimeInterval = 0.033,
        settleDelay: TimeInterval = 0.300,
        ackStallTimeout: TimeInterval = 3.0
    ) {
        precondition(maximumUnackedFrames > 0)
        precondition(minimumFrameInterval >= 0)
        precondition(settleDelay >= 0)
        precondition(ackStallTimeout > 0)
        self.maximumUnackedFrames = maximumUnackedFrames
        self.minimumFrameInterval = minimumFrameInterval
        self.settleDelay = settleDelay
        self.ackStallTimeout = ackStallTimeout
    }

    /// Coalesces a new dirty signal and restarts the settle deadline.
    public mutating func noteDirty(at timestamp: TimeInterval) {
        dirtyGeneration &+= 1
        hasDirtyFrame = true
        settleFramePending = true
        lastDirtyAt = timestamp
    }

    /// Marks a successfully replayed browser input batch as requiring a new capture.
    ///
    /// - Parameter timestamp: Replay time in the caller's monotonic clock domain.
    public mutating func noteInputReplayed(at timestamp: TimeInterval) {
        noteDirty(at: timestamp)
    }

    /// Requests one lossless reconciliation frame from an otherwise idle stream.
    ///
    /// Liveness normally depends on page-driven dirty signals; those can be
    /// silently lost (WebKit suspends `requestAnimationFrame` for occluded
    /// windows, killing the injected beacon). A periodic reconciliation frame
    /// bounds how long the subscriber can display stale content when that
    /// happens. No-op while dirty or settle work is already pending.
    public mutating func requestSettleReconciliation() {
        guard !hasDirtyFrame, !settleFramePending else { return }
        reconcileFramePending = true
    }

    /// Chooses the next capture, deadline, or flow-control state.
    ///
    /// A full unacked window does not block forever: after `ackStallTimeout`
    /// with no acknowledgement progress the in-flight frames are treated as
    /// lost (subscriber not yet wired, connection route swap) and the window
    /// is abandoned in favor of a fresh capture. Frames are self-contained
    /// images, so recapturing instead of retransmitting is always safe.
    /// Without this, acknowledgements for frames the subscriber never saw can
    /// never arrive and the stream deadlocks.
    public mutating func decision(at timestamp: TimeInterval) -> MobileBrowserStreamPacingDecision {
        guard unackedSequences.count < maximumUnackedFrames else {
            guard let windowFullSince else { return .flowControlled }
            let stallRemaining = windowFullSince + ackStallTimeout - timestamp
            if stallRemaining > 0 {
                return .wait(stallRemaining)
            }
            unackedSequences.removeAll()
            self.windowFullSince = nil
            noteDirty(at: timestamp)
            return .captureJPEG(dirtyGeneration: dirtyGeneration)
        }
        if let lastEmissionAt {
            let cadenceRemaining = minimumFrameInterval - max(0, timestamp - lastEmissionAt)
            if cadenceRemaining > 0, hasDirtyFrame || settleFramePending || reconcileFramePending {
                return .wait(cadenceRemaining)
            }
        }
        if hasDirtyFrame {
            return .captureJPEG(dirtyGeneration: dirtyGeneration)
        }
        if reconcileFramePending {
            return .capturePNG(dirtyGeneration: dirtyGeneration)
        }
        if settleFramePending, let lastDirtyAt {
            let settleRemaining = settleDelay - max(0, timestamp - lastDirtyAt)
            if settleRemaining > 0 {
                return .wait(settleRemaining)
            }
            return .capturePNG(dirtyGeneration: dirtyGeneration)
        }
        return .idle
    }

    /// Records a successfully encoded frame and returns its allocated sequence.
    ///
    /// - Parameters:
    ///   - format: Encoding that was emitted.
    ///   - observedDirtyGeneration: Dirty generation captured by the snapshot.
    ///   - timestamp: Emission time in the caller's monotonic clock domain.
    /// - Returns: The allocated sequence, or `nil` if flow control became full.
    public mutating func recordEmission(
        format: MobileBrowserFrameFormat,
        observedDirtyGeneration: UInt64,
        at timestamp: TimeInterval
    ) -> UInt64? {
        guard unackedSequences.count < maximumUnackedFrames else { return nil }
        lastSequence &+= 1
        unackedSequences.append(lastSequence)
        if unackedSequences.count >= maximumUnackedFrames, windowFullSince == nil {
            windowFullSince = timestamp
        }
        lastEmissionAt = timestamp
        guard observedDirtyGeneration == dirtyGeneration else { return lastSequence }
        switch format {
        case .jpeg:
            hasDirtyFrame = false
        case .png:
            hasDirtyFrame = false
            settleFramePending = false
            reconcileFramePending = false
        case .unknown:
            break
        }
        return lastSequence
    }

    /// Applies a cumulative frame acknowledgement.
    public mutating func acknowledge(sequence: UInt64) {
        unackedSequences.removeAll { $0 <= sequence }
        if unackedSequences.count < maximumUnackedFrames {
            windowFullSince = nil
        }
    }
}
