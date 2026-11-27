import CmuxTerminal
import os

/// Preserves Ghostty manual-I/O order while crossing to the tmux main-actor owner.
final class RemoteTmuxPaneInputForwarder: Sendable {
    enum SendResult: Equatable, Sendable {
        case enqueued
        case inactive
        case overflow
    }

    private struct QueuedInput: Sendable {
        let input: TerminalManualInput
        let paneID: Int
        let byteCount: Int
        let epoch: UInt64
    }

    private struct State: Sendable {
        var pendingBytes = 0
        var epoch: UInt64 = 0
        var isActive: Bool
    }

    /// Matches the control connection's bounded stdin budget. The byte
    /// reservation happens before the MainActor hop, where that later budget
    /// cannot protect a stalled consumer.
    static let defaultMaximumPendingBytes = 256 * 1024

    // Ghostty's synchronous callback needs a non-blocking byte/epoch reservation before the actor hop.
    private let state: OSAllocatedUnfairLock<State>
    private let continuation: AsyncStream<QueuedInput>.Continuation
    private let consumer: Task<Void, Never>
    private let maximumPendingBytes: Int
    private let onOverflow: @MainActor @Sendable () -> Void

    @MainActor
    init(
        maximumPendingBytes: Int = RemoteTmuxPaneInputForwarder.defaultMaximumPendingBytes,
        isActive: Bool = true,
        onInput: @escaping @MainActor @Sendable (TerminalManualInput, Int) -> Void,
        onOverflow: @escaping @MainActor @Sendable () -> Void
    ) {
        let maximumPendingBytes = max(1, maximumPendingBytes)
        let state = OSAllocatedUnfairLock(initialState: State(isActive: isActive))
        let (stream, continuation) = AsyncStream.makeStream(
            of: QueuedInput.self,
            // Every event reserves at least one byte, so the byte budget also
            // bounds the element count. A dropped result is still handled as
            // overflow rather than silently losing input.
            bufferingPolicy: .bufferingOldest(maximumPendingBytes)
        )
        self.state = state
        self.continuation = continuation
        self.maximumPendingBytes = maximumPendingBytes
        self.onOverflow = onOverflow
        self.consumer = Task { @MainActor in
            for await queuedInput in stream {
                let shouldDeliver = state.withLock { state in
                    guard queuedInput.epoch == state.epoch else { return false }
                    state.pendingBytes = max(0, state.pendingBytes - queuedInput.byteCount)
                    return state.isActive
                }
                if shouldDeliver {
                    onInput(queuedInput.input, queuedInput.paneID)
                }
            }
        }
    }

    deinit {
        continuation.finish()
        consumer.cancel()
    }

    /// Adds one event from Ghostty's synchronous manual-I/O callback.
    ///
    /// The short lock is the synchronous callback carve-out: it only reserves
    /// bytes and snapshots an epoch. Delivery and connection mutation remain on
    /// the MainActor.
    @discardableResult
    nonisolated func send(_ input: TerminalManualInput, toPane paneID: Int) -> SendResult {
        let byteCount = Self.byteCount(of: input)
        let reservation = state.withLock { state -> (epoch: UInt64, didOverflow: Bool)? in
            guard state.isActive else { return nil }
            guard byteCount <= maximumPendingBytes - state.pendingBytes else {
                state.isActive = false
                state.epoch &+= 1
                state.pendingBytes = 0
                return (state.epoch, true)
            }
            state.pendingBytes += byteCount
            return (state.epoch, false)
        }
        guard let reservation else { return .inactive }
        if reservation.didOverflow {
            Task { @MainActor [onOverflow] in
                onOverflow()
            }
            return .overflow
        }

        let queuedInput = QueuedInput(
            input: input,
            paneID: paneID,
            byteCount: byteCount,
            epoch: reservation.epoch
        )
        switch continuation.yield(queuedInput) {
        case .enqueued:
            return .enqueued
        case .dropped, .terminated:
            return handleYieldFailure()
        @unknown default:
            return handleYieldFailure()
        }
    }

    /// Starts a fresh delivery epoch after reconnect, or invalidates queued
    /// events as soon as the connection leaves its live state.
    @MainActor
    func setConnectionActive(_ isActive: Bool) {
        state.withLock { state in
            guard state.isActive != isActive else { return }
            state.epoch &+= 1
            state.isActive = isActive
            state.pendingBytes = 0
        }
    }

    nonisolated private func handleYieldFailure() -> SendResult {
        state.withLock { state in
            state.isActive = false
            state.epoch &+= 1
            state.pendingBytes = 0
        }
        Task { @MainActor [onOverflow] in
            onOverflow()
        }
        return .overflow
    }

    nonisolated private static func byteCount(of input: TerminalManualInput) -> Int {
        switch input {
        case .bytes(let data):
            return max(1, data.count)
        case .namedKey(let name):
            return max(1, name.utf8.count)
        }
    }
}
