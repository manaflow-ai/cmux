import Foundation

/// Pure per-subscription flow-control and settle-frame state.
public struct MobileBrowserStreamPacing: Equatable, Sendable {
    /// Maximum frames allowed to await acknowledgement.
    public let maximumUnackedFrames: Int
    /// Minimum interval between emitted frames.
    public let minimumFrameInterval: TimeInterval
    /// Quiet interval before a lossless settle frame.
    public let settleDelay: TimeInterval
    /// Most recently allocated sequence, or zero before the first frame.
    public private(set) var lastSequence: UInt64 = 0
    /// Sequences still awaiting cumulative acknowledgement.
    public private(set) var unackedSequences: [UInt64] = []

    private var dirtyGeneration: UInt64 = 0
    private var hasDirtyFrame = false
    private var settleFramePending = false
    private var lastDirtyAt: TimeInterval?
    private var lastEmissionAt: TimeInterval?

    /// Creates pacing state for a new subscription.
    public init(
        maximumUnackedFrames: Int = 3,
        minimumFrameInterval: TimeInterval = 0.033,
        settleDelay: TimeInterval = 0.300
    ) {
        precondition(maximumUnackedFrames > 0)
        precondition(minimumFrameInterval >= 0)
        precondition(settleDelay >= 0)
        self.maximumUnackedFrames = maximumUnackedFrames
        self.minimumFrameInterval = minimumFrameInterval
        self.settleDelay = settleDelay
    }

    /// Coalesces a new dirty signal and restarts the settle deadline.
    public mutating func noteDirty(at timestamp: TimeInterval) {
        dirtyGeneration &+= 1
        hasDirtyFrame = true
        settleFramePending = true
        lastDirtyAt = timestamp
    }

    /// Chooses the next capture, deadline, or flow-control state.
    public func decision(at timestamp: TimeInterval) -> MobileBrowserStreamPacingDecision {
        guard unackedSequences.count < maximumUnackedFrames else {
            return .flowControlled
        }
        if let lastEmissionAt {
            let cadenceRemaining = minimumFrameInterval - max(0, timestamp - lastEmissionAt)
            if cadenceRemaining > 0, hasDirtyFrame || settleFramePending {
                return .wait(cadenceRemaining)
            }
        }
        if hasDirtyFrame {
            return .captureJPEG(dirtyGeneration: dirtyGeneration)
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
        lastEmissionAt = timestamp
        guard observedDirtyGeneration == dirtyGeneration else { return lastSequence }
        switch format {
        case .jpeg:
            hasDirtyFrame = false
        case .png:
            hasDirtyFrame = false
            settleFramePending = false
        case .unknown:
            break
        }
        return lastSequence
    }

    /// Applies a cumulative frame acknowledgement.
    public mutating func acknowledge(sequence: UInt64) {
        unackedSequences.removeAll { $0 <= sequence }
    }
}
