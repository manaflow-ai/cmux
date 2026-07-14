import CMUXMobileCore
internal import CmuxMobileDiagnostics
import Foundation

extension MobileShellComposite {
    /// Reduces one sequence-stamped live PTY event against the authoritative
    /// delivered high-water mark before it enters the surface queue. The
    /// interval stays attached to retained barrier output so fail-open can run
    /// the same reducer again against the replay that won the barrier.
    @discardableResult
    func deliverSequencedTerminalBytes(
        _ bytes: Data,
        startSeq: UInt64,
        surfaceID: String,
        bypassReplayBarrier: Bool = false
    ) -> Bool {
        guard let interval = TerminalOutputDelivery.ByteSequenceInterval(
            start: startSeq,
            byteCount: bytes.count
        ) else {
            MobileDebugLog.anchormux(
                "sync.byte_interval_invalid surface=\(surfaceID) start=\(startSeq) bytes=\(bytes.count)"
            )
            return false
        }
        return reduceTerminalByteDelivery(
            TerminalOutputDelivery(
                bytes: bytes,
                replaceable: false,
                byteSequenceInterval: interval,
                viewportPolicy: .natural
            ),
            surfaceID: surfaceID,
            bypassReplayBarrier: bypassReplayBarrier
        )
    }

    /// The single sequence-aware raw-byte reducer for live events and retained
    /// replay-barrier output. Sequence-less direct and replay payloads pass
    /// through unchanged; stamped events are trimmed, queued, then marked.
    @discardableResult
    func reduceTerminalByteDelivery(
        _ delivery: TerminalOutputDelivery,
        surfaceID: String,
        bypassReplayBarrier: Bool
    ) -> Bool {
        guard let interval = delivery.byteSequenceInterval else {
            return deliverTerminalOutput(
                delivery,
                surfaceID: surfaceID,
                bypassReplayBarrier: bypassReplayBarrier
            )
        }

        var reducedDelivery = delivery
        var hasSequenceGap = false
        if let deliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] {
            if interval.start > deliveredSeq {
                hasSequenceGap = true
                MobileDebugLog.anchormux(
                    "sync.byte_gap surface=\(surfaceID) delivered=\(deliveredSeq) next=\(interval.start)"
                )
                diagnosticLog?.record(DiagnosticEvent(
                    .byteGap,
                    surface: Self.diagnosticSurfaceHandle(surfaceID),
                    a: Int(clamping: deliveredSeq),
                    b: Int(clamping: interval.start)
                ))
            } else if interval.end <= deliveredSeq {
                return true
            } else if interval.start < deliveredSeq {
                let overlap = Int(deliveredSeq - interval.start)
                guard let trimmed = delivery.droppingBytePrefix(overlap) else { return false }
                reducedDelivery = trimmed
            }
        } else if let floorSeq = terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] {
            if interval.end <= floorSeq {
                MobileDebugLog.anchormux(
                    "sync.bytes_below_floor surface=\(surfaceID) floor=\(floorSeq) end=\(interval.end)"
                )
                return true
            }
            if interval.start < floorSeq {
                let overlap = Int(floorSeq - interval.start)
                guard let trimmed = delivery.droppingBytePrefix(overlap) else { return false }
                reducedDelivery = trimmed
            }
        }

        let retainedByActiveBarrier = terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil
            && !bypassReplayBarrier
        guard deliverTerminalOutput(
            reducedDelivery,
            surfaceID: surfaceID,
            bypassReplayBarrier: bypassReplayBarrier
        ) else {
            return false
        }
        // Reaching the dropped-output cap synchronously fails the barrier open,
        // and reconciliation above has already reduced and marked this exact
        // delivery. Do not run its sequence transition twice in the outer call.
        if retainedByActiveBarrier {
            return true
        }

        markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: interval.end)
        if hasSequenceGap {
            if terminalReplaySurfaceIDsInFlight.contains(surfaceID) {
                cancelTerminalReplayInFlight(surfaceID: surfaceID)
            }
            resyncTerminalOutput(
                reason: "seq_gap",
                restartEventStream: false,
                surfaceIDs: [surfaceID]
            )
        }
        return true
    }
}
