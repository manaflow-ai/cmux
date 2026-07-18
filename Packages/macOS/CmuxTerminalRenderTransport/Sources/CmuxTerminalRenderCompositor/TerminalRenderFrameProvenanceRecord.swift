public import CmuxTerminalRenderProtocol
public import CmuxTerminalRenderTransport
public import Foundation

/// Synchronous constant-time audit hook invoked before an accepted frame can
/// be released or a submitted blit can be committed.
public typealias TerminalRenderFrameDispositionHandler = @Sendable (
    TerminalRenderFrame,
    TerminalRenderCompositorEnqueueResult
) -> Void

/// Called only after Core Animation confirms that a committed drawable became
/// visible. Submission and coalescing are deliberately not presentation proof.
public typealias TerminalRenderFramePresentedHandler = @Sendable (
    TerminalRenderFrameMetadata
) -> Void

/// Stable structured outcome for one authenticated frame offered to Swift's
/// final compositor boundary.
public struct TerminalRenderFrameProvenanceRecord: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Equatable, Sendable {
        case submitted
        case coalesced
        case drawableUnavailable = "drawable_unavailable"
        case rejected
        case invalidSurface = "invalid_surface"
        case metalUnavailable = "metal_unavailable"
    }

    public let monotonicNanoseconds: UInt64
    public let workerProcessID: Int32
    public let workerEffectiveUserID: UInt32
    public let daemonInstanceID: UUID
    public let workspaceID: UUID
    public let terminalID: UUID
    public let terminalEpoch: UInt64
    public let terminalSequence: UInt64
    public let rendererEpoch: UInt64
    public let presentationID: UUID
    public let presentationGeneration: UInt64
    public let frameSequence: UInt64
    public let width: UInt32
    public let height: UInt32
    public let surfaceID: UInt32
    public let disposition: Disposition
    public let rejectionReason: String?

    /// Captures all process, terminal, presentation, IOSurface, and compositor
    /// fences before the worker is allowed to reuse this frame's pool slot.
    public init(
        monotonicNanoseconds: UInt64,
        workspaceID: UUID,
        frame: TerminalRenderFrame,
        result: TerminalRenderCompositorEnqueueResult
    ) {
        self.monotonicNanoseconds = monotonicNanoseconds
        workerProcessID = frame.workerIdentity.processID
        workerEffectiveUserID = frame.workerIdentity.effectiveUserID
        daemonInstanceID = frame.metadata.daemonInstanceID
        self.workspaceID = workspaceID
        terminalID = frame.metadata.terminalID
        terminalEpoch = frame.metadata.terminalEpoch
        terminalSequence = frame.metadata.terminalSequence
        rendererEpoch = frame.metadata.rendererEpoch
        presentationID = frame.metadata.presentationID
        presentationGeneration = frame.metadata.presentationGeneration
        frameSequence = frame.metadata.frameSequence
        width = frame.metadata.width
        height = frame.metadata.height
        surfaceID = frame.surface.identifier
        disposition = Self.disposition(result)
        rejectionReason = Self.rejectionReason(result)
    }

    private static func disposition(
        _ result: TerminalRenderCompositorEnqueueResult
    ) -> Disposition {
        switch result {
        case .submitted: .submitted
        case .coalesced: .coalesced
        case .drawableUnavailable: .drawableUnavailable
        case .rejected: .rejected
        case .invalidSurface: .invalidSurface
        case .metalUnavailable: .metalUnavailable
        }
    }

    private static func rejectionReason(
        _ result: TerminalRenderCompositorEnqueueResult
    ) -> String? {
        guard case let .rejected(reason) = result else { return nil }
        return switch reason {
        case .daemonInstanceMismatch: "daemon_instance_mismatch"
        case .rendererEpochMismatch: "renderer_epoch_mismatch"
        case .terminalIdentityMismatch: "terminal_identity_mismatch"
        case .terminalEpochMismatch: "terminal_epoch_mismatch"
        case .staleTerminalSequence: "stale_terminal_sequence"
        case .presentationIdentityMismatch: "presentation_identity_mismatch"
        case .presentationGenerationMismatch: "presentation_generation_mismatch"
        case .dimensionsMismatch: "dimensions_mismatch"
        case .pixelFormatMismatch: "pixel_format_mismatch"
        case .colorSpaceMismatch: "color_space_mismatch"
        case .completionModeMismatch: "completion_mode_mismatch"
        case .completionFenceIdentityMismatch: "completion_fence_identity_mismatch"
        case .staleCompletionFence: "stale_completion_fence"
        case .staleFrameSequence: "stale_frame_sequence"
        }
    }
}

/// Bounded in-memory audit stream. Recording never performs file I/O on the
/// AppKit main actor; acceptance tooling can snapshot and encode it later.
public final class TerminalRenderFrameProvenanceBuffer: @unchecked Sendable {
    public let capacity: Int

    private let lock = NSLock()
    private var storage: [TerminalRenderFrameProvenanceRecord?]
    private var writeIndex = 0
    private var storedCount = 0
    private var totalRecordCount: UInt64 = 0
    private var droppedRecordCount: UInt64 = 0

    public init(capacity: Int = 4_096) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }

    public func append(_ record: TerminalRenderFrameProvenanceRecord) {
        lock.lock()
        defer { lock.unlock() }
        totalRecordCount &+= 1
        if storedCount == capacity {
            droppedRecordCount &+= 1
        } else {
            storedCount += 1
        }
        storage[writeIndex] = record
        writeIndex = (writeIndex + 1) % capacity
    }

    public func snapshot() -> TerminalRenderFrameProvenanceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    /// Returns the exact prior interval and clears the bounded ring while
    /// holding one lock. Existing record values remain valid in the snapshot.
    @discardableResult
    public func snapshotAndReset() -> TerminalRenderFrameProvenanceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let result = snapshotLocked()
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        storedCount = 0
        totalRecordCount = 0
        droppedRecordCount = 0
        return result
    }

    private func snapshotLocked() -> TerminalRenderFrameProvenanceSnapshot {
        let start = storedCount == capacity ? writeIndex : 0
        let records = (0 ..< storedCount).compactMap { offset in
            storage[(start + offset) % capacity]
        }
        return TerminalRenderFrameProvenanceSnapshot(
            totalRecordCount: totalRecordCount,
            droppedRecordCount: droppedRecordCount,
            records: records
        )
    }
}

public struct TerminalRenderFrameProvenanceSnapshot: Codable, Equatable, Sendable {
    public let totalRecordCount: UInt64
    public let droppedRecordCount: UInt64
    public let records: [TerminalRenderFrameProvenanceRecord]

    public init(
        totalRecordCount: UInt64,
        droppedRecordCount: UInt64,
        records: [TerminalRenderFrameProvenanceRecord]
    ) {
        self.totalRecordCount = totalRecordCount
        self.droppedRecordCount = droppedRecordCount
        self.records = records
    }
}
