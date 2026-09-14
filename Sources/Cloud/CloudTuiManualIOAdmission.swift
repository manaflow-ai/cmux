import os

/// Bounds payloads before a synchronous callback hands them to a socket queue.
final class CloudTuiManualIOAdmission: Sendable {
    private let maximumBytes: Int
    private let maximumItems: Int
    // A callback cannot await an actor before retaining its payload. This lock
    // protects only short reservation-counter updates, never I/O or domain state.
    private let state = OSAllocatedUnfairLock(initialState: (bytes: 0, items: 0, closed: false))

    init(maximumBytes: Int = 256 * 1024, maximumItems: Int = 16 * 1024) {
        self.maximumBytes = maximumBytes
        self.maximumItems = maximumItems
    }

    /// Reserves before retaining a payload, closing admission on the first overflow.
    func reserve(_ bytes: Int) -> CloudTuiManualIOAdmissionResult {
        state.withLock { state in
            guard !state.closed else { return .closed }
            guard bytes >= 0, bytes <= maximumBytes - state.bytes,
                  state.items < maximumItems else {
                state.closed = true
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

    /// Rejects new callbacks without erasing outstanding reservations.
    func close() { state.withLock { $0.closed = true } }

    /// Rebinding opens admission without erasing outstanding reservations.
    func reopen() { state.withLock { $0.closed = false } }
}
