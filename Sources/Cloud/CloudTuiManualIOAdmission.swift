import os

/// Bounds payloads before a synchronous callback hands them to a socket queue.
final class CloudTuiManualIOAdmission: Sendable {
    private let maximumBytes: Int
    private let maximumItems: Int
    // A callback cannot await an actor before retaining its payload. This lock
    // protects only short reservation-counter updates, never I/O or domain state.
    private let state = OSAllocatedUnfairLock(initialState: (
        bytes: 0, items: 0, phase: CloudTuiManualIOAdmissionPhase.open
    ))

    init(maximumBytes: Int = 256 * 1024, maximumItems: Int = 16 * 1024) {
        self.maximumBytes = maximumBytes
        self.maximumItems = maximumItems
    }

    /// Reserves before retaining a payload, closing admission on the first overflow.
    func reserve(_ bytes: Int) -> CloudTuiManualIOAdmissionResult {
        state.withLock { state in
            guard state.phase == .open else { return .closed }
            guard bytes >= 0, bytes <= maximumBytes - state.bytes,
                  state.items < maximumItems else {
                state.phase = .saturated
                return .rejected
            }
            state.bytes += bytes
            state.items += 1
            return .reserved
        }
    }

    /// Releases exactly one successful reservation when its callback finishes.
    func release(_ bytes: Int) {
        state.withLock { state in
            state.bytes -= bytes
            state.items -= 1
        }
    }

    /// Permanently rejects new callbacks, including from an already-queued bind.
    func invalidate() { state.withLock { $0.phase = .invalidated } }

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
