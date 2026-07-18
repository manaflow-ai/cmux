import CmuxTerminalRenderCompositor
import CmuxTerminalRenderProtocol
import CmuxTerminalRenderTransport
import Dispatch
import Foundation
import GhosttyKit

/// Small lock-protected value captured by off-main compositor callbacks. A
/// terminal can move workspaces without recreating its compositor, so copying
/// the workspace UUID into the callback would make later provenance stale.
final class TerminalBackendRenderDiagnosticsWorkspaceContext: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UUID

    init(_ workspaceID: UUID) {
        storage = workspaceID
    }

    func update(_ workspaceID: UUID) {
        lock.lock()
        storage = workspaceID
        lock.unlock()
    }

    func current() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Process-scoped, bounded proof of the Swift host's final compositor work.
///
/// Recording is lock-only and performs no JSON encoding or file I/O on frame
/// delivery. The debug socket snapshots it later on a worker thread.
final class TerminalBackendRenderDiagnostics: @unchecked Sendable {
    static let shared = TerminalBackendRenderDiagnostics()

    /// Eight terminals at 60 visible frames per second for 60 seconds produce
    /// 28,800 rows. Keep more than twice that acceptance workload bounded in
    /// memory so the proof itself does not drop evidence.
    private static let defaultProvenanceCapacity = 65_536

    private struct Counters {
        var receivedFrames: UInt64 = 0
        var admittedFrames: UInt64 = 0
        var submittedBlits: UInt64 = 0
        var coalescedFrames: UInt64 = 0
        var rejectedFrames: UInt64 = 0
        var drawableUnavailableEvents: UInt64 = 0
        var metalUnavailableFrames: UInt64 = 0
    }

    private struct Snapshot {
        let counters: Counters
        let totalRecordCount: UInt64
        let droppedRecordCount: UInt64
        let records: [TerminalRenderFrameProvenanceRecord]
    }

    private struct FrameKey: Hashable {
        let daemonInstanceID: UUID
        let rendererEpoch: UInt64
        let presentationID: UUID
        let presentationGeneration: UInt64
        let frameSequence: UInt64
        let surfaceID: UInt32

        init(frame: TerminalRenderFrame) {
            daemonInstanceID = frame.metadata.daemonInstanceID
            rendererEpoch = frame.metadata.rendererEpoch
            presentationID = frame.metadata.presentationID
            presentationGeneration = frame.metadata.presentationGeneration
            frameSequence = frame.metadata.frameSequence
            surfaceID = frame.surface.identifier
        }

        init(record: TerminalRenderFrameProvenanceRecord) {
            daemonInstanceID = record.daemonInstanceID
            rendererEpoch = record.rendererEpoch
            presentationID = record.presentationID
            presentationGeneration = record.presentationGeneration
            frameSequence = record.frameSequence
            surfaceID = record.surfaceID
        }
    }

    private let lock = NSLock()
    private let provenanceCapacity: Int
    private var counters = Counters()
    private var provenance: [TerminalRenderFrameProvenanceRecord?]
    private var provenanceWriteIndex = 0
    private var provenanceStoredCount = 0
    private var provenanceTotalCount: UInt64 = 0
    private var provenanceDroppedCount: UInt64 = 0
    private var provenanceIndices: [FrameKey: Int] = [:]

    init(capacity: Int = defaultProvenanceCapacity) {
        precondition(capacity > 0)
        provenanceCapacity = capacity
        provenance = Array(repeating: nil, count: capacity)
    }

    func record(
        workspaceID: UUID,
        frame: TerminalRenderFrame,
        result: TerminalRenderCompositorEnqueueResult
    ) {
        let record = TerminalRenderFrameProvenanceRecord(
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            workspaceID: workspaceID,
            frame: frame,
            result: result
        )
        lock.lock()
        defer { lock.unlock() }

        let key = FrameKey(frame: frame)
        if let index = provenanceIndices[key], let previous = provenance[index] {
            recordTransition(from: previous.disposition, to: result)
            provenance[index] = record
            return
        }

        // Receipt, admission result, and provenance enter one interval under
        // one lock. This makes receivedFrames == provenanceTotalCount true by
        // construction even when acceptance resets race a frame producer.
        counters.receivedFrames &+= 1
        recordInitial(result)

        provenanceTotalCount &+= 1
        if provenanceStoredCount == provenanceCapacity {
            provenanceDroppedCount &+= 1
            if let replaced = provenance[provenanceWriteIndex] {
                provenanceIndices.removeValue(forKey: FrameKey(record: replaced))
            }
        } else {
            provenanceStoredCount += 1
        }
        provenance[provenanceWriteIndex] = record
        provenanceIndices[key] = provenanceWriteIndex
        provenanceWriteIndex = (provenanceWriteIndex + 1) % provenanceCapacity
    }

    private func recordInitial(_ result: TerminalRenderCompositorEnqueueResult) {
        switch result {
        case .submitted:
            counters.admittedFrames &+= 1
            counters.submittedBlits &+= 1
        case .coalesced:
            counters.admittedFrames &+= 1
            counters.coalescedFrames &+= 1
        case .drawableUnavailable:
            counters.admittedFrames &+= 1
            counters.drawableUnavailableEvents &+= 1
        case .rejected:
            counters.rejectedFrames &+= 1
        case .invalidSurface:
            counters.admittedFrames &+= 1
            counters.rejectedFrames &+= 1
        case .metalUnavailable:
            counters.admittedFrames &+= 1
            counters.rejectedFrames &+= 1
            counters.metalUnavailableFrames &+= 1
        }
    }

    private func recordTransition(
        from previous: TerminalRenderFrameProvenanceRecord.Disposition,
        to result: TerminalRenderCompositorEnqueueResult
    ) {
        switch result {
        case .submitted:
            if previous != .submitted {
                counters.submittedBlits &+= 1
            }
        case .coalesced:
            if previous != .coalesced {
                counters.coalescedFrames &+= 1
            }
        case .drawableUnavailable:
            counters.drawableUnavailableEvents &+= 1
        case .rejected:
            if previous != .rejected {
                counters.rejectedFrames &+= 1
            }
        case .invalidSurface:
            if previous != .invalidSurface {
                counters.rejectedFrames &+= 1
            }
        case .metalUnavailable:
            if previous != .metalUnavailable {
                counters.rejectedFrames &+= 1
                counters.metalUnavailableFrames &+= 1
            }
        }
    }

    /// Returns one interval. `reset` returns the interval that was cleared, so
    /// callers can prove the pre-capture boundary instead of losing it.
    func payload(reset: Bool) -> [String: Any] {
        let snapshot = snapshot(reset: reset)
        // The Ghostty library emits the snapshot itself. Instruments therefore
        // binds the monotonic constructor evidence to this process PID instead
        // of trusting counters serialized by the Swift caller.
        let ghosttyProcessCensus = ghostty_process_census_emit_signpost_snapshot()
        let recordPayloads = snapshot.records.map(Self.recordPayload)
        let recordedCount = snapshot.totalRecordCount
        let receivedCount = snapshot.counters.receivedFrames

        return [
            "schema_version": 1,
            "reset_after_snapshot": reset,
            "ghostty_process_census": [
                "schema_version": ghosttyProcessCensus.schema_version,
                "runtime_app_constructor_attempts": ghosttyProcessCensus.runtime_app_constructor_attempts,
                "surface_constructor_attempts": ghosttyProcessCensus.surface_constructor_attempts,
                "manual_io_surface_constructor_attempts": ghosttyProcessCensus.manual_io_surface_constructor_attempts,
                "embedded_pty_surface_constructor_attempts": ghosttyProcessCensus.embedded_pty_surface_constructor_attempts,
                "pty_master_open_attempts": ghosttyProcessCensus.pty_master_open_attempts,
                "pty_master_allocations": ghosttyProcessCensus.pty_master_allocations,
            ],
            "metrics": [
                "received_frames": snapshot.counters.receivedFrames,
                "admitted_frames": snapshot.counters.admittedFrames,
                "submitted_blits": snapshot.counters.submittedBlits,
                "coalesced_frames": snapshot.counters.coalescedFrames,
                "rejected_frames": snapshot.counters.rejectedFrames,
                "drawable_unavailable_events": snapshot.counters.drawableUnavailableEvents,
                "metal_unavailable_frames": snapshot.counters.metalUnavailableFrames,
                "provenance_records": recordedCount,
                "provenance_dropped_records": snapshot.droppedRecordCount,
                "missing_provenance_records": receivedCount > recordedCount
                    ? receivedCount - recordedCount
                    : 0,
            ],
            "provenance": [
                "capacity": provenanceCapacity,
                "total_record_count": recordedCount,
                "dropped_record_count": snapshot.droppedRecordCount,
                "records": recordPayloads,
            ],
        ]
    }

    private func snapshot(reset: Bool) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let start = provenanceStoredCount == provenanceCapacity
            ? provenanceWriteIndex
            : 0
        let records = (0 ..< provenanceStoredCount).compactMap { offset in
            provenance[(start + offset) % provenanceCapacity]
        }
        let result = Snapshot(
            counters: counters,
            totalRecordCount: provenanceTotalCount,
            droppedRecordCount: provenanceDroppedCount,
            records: records
        )
        if reset {
            counters = Counters()
            provenance = Array(repeating: nil, count: provenanceCapacity)
            provenanceWriteIndex = 0
            provenanceStoredCount = 0
            provenanceTotalCount = 0
            provenanceDroppedCount = 0
            provenanceIndices.removeAll(keepingCapacity: true)
        }
        return result
    }

    private static func recordPayload(
        _ record: TerminalRenderFrameProvenanceRecord
    ) -> [String: Any] {
        [
            "monotonic_nanoseconds": record.monotonicNanoseconds,
            "worker_pid": record.workerProcessID,
            "worker_effective_uid": record.workerEffectiveUserID,
            "daemon_instance_id": record.daemonInstanceID.uuidString,
            "workspace_id": record.workspaceID.uuidString,
            "terminal_id": record.terminalID.uuidString,
            "terminal_epoch": record.terminalEpoch,
            "terminal_sequence": record.terminalSequence,
            "renderer_epoch": record.rendererEpoch,
            "presentation_id": record.presentationID.uuidString,
            "presentation_generation": record.presentationGeneration,
            "frame_sequence": record.frameSequence,
            "width": record.width,
            "height": record.height,
            "iosurface_id": record.surfaceID,
            "disposition": record.disposition.rawValue,
            "rejection_reason": record.rejectionReason as Any? ?? NSNull(),
        ]
    }
}
