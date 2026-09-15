import os

/// Bounds payloads before a synchronous callback hands them to a socket queue.
final class CloudTuiManualIOAdmission: Sendable {
    private let maximumBytes: Int
    private let maximumItems: Int
    private let maximumFramedBytes = 2 * 1024 * 1024
    // A callback cannot await an actor before retaining its payload. This lock
    // protects only short reservation-counter updates, never I/O or domain state.
    private let state = OSAllocatedUnfairLock(initialState: (
        bytes: 0, framedBytes: 0, items: 0, phase: CloudTuiManualIOAdmissionPhase.open,
        continuation: Optional<AsyncStream<Void>.Continuation>.none
    ))

    init(maximumBytes: Int = 256 * 1024, maximumItems: Int = 16 * 1024) {
        self.maximumBytes = maximumBytes
        self.maximumItems = maximumItems
    }

    /// Each binding owns a fresh bounded stream; canceling an old observer must
    /// not terminate the replacement binding's capacity notifications.
    var capacityChanges: AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let (previous, closed) = state.withLock { state in
                let previous = state.continuation
                let closed = state.phase == .invalidated
                if !closed { state.continuation = continuation }
                return (previous, closed)
            }
            previous?.finish()
            if closed { continuation.finish() }
            else { continuation.yield(()) }
        }
    }

    /// Reserves before retaining a payload, closing admission on the first overflow.
    func reserve(_ bytes: Int, framedBytes: Int = 0) -> CloudTuiManualIOAdmissionResult {
        state.withLock { state in
            guard state.phase == .open else { return .closed }
            guard bytes >= 0, bytes <= maximumBytes - state.bytes,
                  state.items < maximumItems, framedBytes >= 0,
                  framedBytes <= maximumFramedBytes - state.framedBytes else {
                state.phase = .saturated
                return .rejected
            }
            state.bytes += bytes
            state.framedBytes += framedBytes
            state.items += 1
            return .reserved
        }
    }

    /// Releases only after the final owner drops its payload or receipt credit.
    func release(_ bytes: Int, framedBytes: Int = 0) {
        let continuation = state.withLock { state in
            state.bytes -= bytes
            state.framedBytes -= framedBytes
            state.items -= 1
            if state.phase == .saturated { state.phase = .open }
            return state.continuation
        }
        continuation?.yield(())
    }

    /// Permanently rejects new callbacks, including from an already-queued bind.
    func invalidate() {
        let continuation = state.withLock { state in
            state.phase = .invalidated
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.finish()
    }

    /// Fences new callbacks when the downstream pending buffer is full.
    func saturate() {
        state.withLock { state in
            if state.phase == .open { state.phase = .saturated }
        }
    }

    /// Rebinding opens admission without erasing outstanding reservations.
    @discardableResult
    func reopen() -> Bool {
        state.withLock { state in
            guard state.phase != .invalidated else { return false }
            state.phase = .open
            return true
        }
    }
}
