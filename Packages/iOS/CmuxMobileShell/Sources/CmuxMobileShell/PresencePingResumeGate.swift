internal import os

/// Admits exactly one completion from a WebSocket ping callback.
final class PresencePingResumeGate: Sendable {
    // lint:allow lock - URLSession ping callbacks need a synchronous one-bit
    // compare-and-set before they can resume a checked continuation.
    private let didResume = OSAllocatedUnfairLock(initialState: false)

    func claim() -> Bool {
        didResume.withLock { didResume in
            guard !didResume else { return false }
            didResume = true
            return true
        }
    }
}
