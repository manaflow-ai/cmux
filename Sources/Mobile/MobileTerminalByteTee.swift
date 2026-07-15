import CmuxFoundation
import CmuxTerminal
import Foundation
import OSLog
import os

private let mobileTerminalByteTeeLog = Logger(
    subsystem: "dev.cmux",
    category: "mobile-terminal-byte-tee"
)

/// Captures raw PTY-output bytes from every cmux terminal surface and
/// publishes them to subscribed mobile clients as `terminal.bytes`
/// events. Provides a per-surface ring buffer that mobile clients can
/// replay from as a fallback; the primary mobile replay path sends a
/// bounded render-grid snapshot because a byte tail is not a complete
/// screen state for TUIs.
///
/// The byte source is libghostty's `ghostty_surface_set_pty_tee_cb`
/// callback (cmux fork addition). The callback fires on the IO read
/// thread before the VT parser sees the bytes, so the bytes the
/// iPhone receives are byte-identical to what the Mac's own libghostty
/// surface will process.
///
/// This class is intentionally lock-light: the hot path is just an
/// atomic load of a per-surface queue, a `memcpy` into a buffer, and a
/// non-blocking enqueue onto a serial dispatch queue that handles
/// fan-out. Cross-thread safety: the callback can fire on any thread;
/// publish handles the hop to the main `MobileHostService.emitEvent`.
@MainActor
final class MobileTerminalByteTee {
    struct OutputChunk: Sendable {
        let sequence: UInt64
        let data: Data
    }

    // nonisolated: the singleton itself is an immutable `let` constructed once;
    // the only cross-thread entry point (`append`, from the C tee trampoline) is
    // `nonisolated` and hops to the main actor internally, so reading the
    // reference off the ghostty output thread is safe.
    nonisolated static let shared = MobileTerminalByteTee()

    private struct SurfaceState {
        /// Monotonic byte-stream sequence. Each emitted chunk advances by
        /// chunk length so the iPhone can detect drops.
        var seq: UInt64 = 0
        /// Tail-trimmed ring (~256 KB) for replay on cold attach.
        var replayBuffer: Data = Data()
    }

    private var statesBySurfaceID: [UUID: SurfaceState] = [:]
    private var laneContinuationsBySurfaceID: [
        UUID: [UUID: AsyncStream<OutputChunk>.Continuation]
    ] = [:]
    nonisolated private let laneSubscriberCount = OSAllocatedUnfairLock(initialState: 0)
    nonisolated private let laneDemand = AtomicBooleanGate(false)
    private let replayBudget: Int = 256 * 1024
    /// Serial queue so fan-out preserves byte order even though the
    /// upstream callback runs off the main thread.
    private let publishQueue = DispatchQueue(
        label: "dev.cmux.mobile.byte-tee.publish",
        qos: .userInitiated
    )

    // nonisolated: the initializer only assigns default-initialized stored
    // properties (no main-actor work), so the `nonisolated(unsafe) static let
    // shared` can construct it without hopping to the main actor.
    nonisolated private init() {}

    /// Non-isolated entry point called from the C tee trampoline. Safe
    /// to invoke from any thread.
    nonisolated func append(surfaceID: UUID, bytes: UnsafeBufferPointer<UInt8>) {
        // Hot path: this runs on the Ghostty PTY/IO read thread for *every*
        // surface, including normal desktop use with no phone attached. Bail
        // before any allocation or main-actor hop when no mobile client wants
        // these bytes. The check is an O(1) dictionary read of the single
        // subscription source of truth (`MobileHostEventSubscriptionTracker`),
        // the same accessor `MobileTerminalRenderObserver` already uses; it is
        // not a new lock, and its only writers are the rare subscribe /
        // unsubscribe RPCs, so the IO thread never meaningfully contends. We
        // gate on both topics because `publishFromMain` is load-bearing for
        // the render-grid stream too: it advances `seq` (read as `stateSeq`)
        // and calls `noteTerminalBytes` to schedule the post-parse tick.
        // Iroh application-lane demand keeps its lock-free gate.
        guard
            MobileHostService.hasEventSubscribers(topic: "terminal.bytes")
                || MobileHostService.hasEventSubscribers(topic: "terminal.render_grid")
                || laneDemand.loadAcquire()
        else {
            return
        }
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        let copy = Data(bytes: base, count: bytes.count)
        publishQueue.async { [weak self] in
            Task { @MainActor [weak self] in
                self?.publishFromMain(surfaceID: surfaceID, data: copy)
            }
        }
    }

    /// The replay buffer for a surface, suitable for sending in response
    /// to a `mobile.terminal.replay` RPC on cold attach. Returns the
    /// current sequence so the iPhone can chain subsequent live events.
    func replayState(surfaceID: UUID) -> (seq: UInt64, data: Data)? {
        guard let state = statesBySurfaceID[surfaceID] else { return nil }
        return (state.seq, state.replayBuffer)
    }

    func currentSequence(surfaceID: UUID) -> UInt64? {
        statesBySurfaceID[surfaceID]?.seq
    }

    /// Opens a bounded raw-output subscription for one authenticated Iroh
    /// terminal lane. If a slow consumer drops a chunk, the stream ends so the
    /// phone must reopen with its last byte cursor instead of rendering a gap.
    func outputUpdates(surfaceID: UUID) -> AsyncStream<OutputChunk> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            laneContinuationsBySurfaceID[surfaceID, default: [:]][id] = continuation
            laneSubscriberCount.withLock { $0 += 1 }
            laneDemand.storeRelease(true)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.removeLaneContinuation(id: id, surfaceID: surfaceID)
                }
            }
        }
    }

    /// Drop replay history for a surface (e.g. when the surface closes).
    func dropSurface(surfaceID: UUID) {
        statesBySurfaceID.removeValue(forKey: surfaceID)
        let continuations = laneContinuationsBySurfaceID.removeValue(forKey: surfaceID)
            .map { Array($0.values) } ?? []
        if !continuations.isEmpty {
            let remainingCount = laneSubscriberCount.withLock { count in
                count = max(0, count - continuations.count)
                return count
            }
            laneDemand.storeRelease(remainingCount > 0)
            for continuation in continuations {
                continuation.finish()
            }
        }
    }

    private func publishFromMain(surfaceID: UUID, data: Data) {
        var state = statesBySurfaceID[surfaceID] ?? SurfaceState()
        let chunkSeq = state.seq
        state.seq &+= UInt64(data.count)
        state.replayBuffer.append(data)
        if state.replayBuffer.count > replayBudget {
            state.replayBuffer.removeFirst(state.replayBuffer.count - replayBudget)
        }
        statesBySurfaceID[surfaceID] = state
        MobileTerminalRenderObserver.shared.noteTerminalBytes(surfaceID: surfaceID)

        if let continuations = laneContinuationsBySurfaceID[surfaceID] {
            let chunk = OutputChunk(sequence: chunkSeq, data: data)
            var droppedIDs: [UUID] = []
            for (id, continuation) in continuations {
                if case .dropped = continuation.yield(chunk) {
                    continuation.finish()
                    droppedIDs.append(id)
                }
            }
            for id in droppedIDs {
                removeLaneContinuation(id: id, surfaceID: surfaceID)
            }
        }

        // The render-grid path (the primary mobile path) only needs the seq
        // advance + `noteTerminalBytes` tick above; it never consumes the raw
        // `terminal.bytes` wire payload. Gate the base64 allocation and its
        // fan-out on whether anyone is actually subscribed to `terminal.bytes`,
        // so render-grid-only attaches don't pay for it on the output hot path.
        // The check is the same O(1) subscription read used elsewhere; the
        // `seq`/render-grid work above stays unconditional so render-grid
        // subscribers keep correct sequence continuity.
        guard MobileHostService.hasEventSubscribers(topic: "terminal.bytes") else { return }

        // JSON+base64 stopgap for the wire format. A future commit can
        // switch to a binary opcode on the same connection if PTY
        // throughput becomes a bottleneck.
        let payload: [String: Any] = [
            "surface_id": surfaceID.uuidString,
            "seq": chunkSeq,
            "data_b64": data.base64EncodedString(),
        ]
        MobileHostService.shared.emitEvent(topic: "terminal.bytes", payload: payload)
    }

    private func removeLaneContinuation(id: UUID, surfaceID: UUID) {
        guard laneContinuationsBySurfaceID[surfaceID]?.removeValue(forKey: id) != nil else {
            return
        }
        if laneContinuationsBySurfaceID[surfaceID]?.isEmpty == true {
            laneContinuationsBySurfaceID[surfaceID] = nil
        }
        let remainingCount = laneSubscriberCount.withLock { count in
            count = max(0, count - 1)
            return count
        }
        laneDemand.storeRelease(remainingCount > 0)
    }
}
