import os

/// Records the one-shot deallocation callback for a test-owned standard-input payload.
final class CommandStandardInputPayloadReleaseProbe: Sendable {
    // The Data deallocator is synchronous and non-async, so a lock protects this tiny flag.
    private let released = OSAllocatedUnfairLock(initialState: false)

    var wasReleased: Bool {
        released.withLock { $0 }
    }

    func markReleased() {
        released.withLock { $0 = true }
    }
}
