import os

final class NotificationBoolRecorder: Sendable {
    // Synchronous NotificationCenter observers can run on the posting thread.
    private let valueLock = OSAllocatedUnfairLock(initialState: false)

    var value: Bool {
        valueLock.withLock { $0 }
    }

    func setTrue() {
        valueLock.withLock { $0 = true }
    }
}
