import Darwin
import os

/// Records synchronous process-signal requests from a Sendable callback.
final class ProcessSignalRecorder: Sendable {
    // Signal callbacks are synchronous and non-async; an actor would add ordering hops.
    private let recordedSignals = OSAllocatedUnfairLock(initialState: [Int32]())

    func record(processGroupID _: pid_t, signal: Int32) {
        recordedSignals.withLock { $0.append(signal) }
    }

    func snapshot() -> [Int32] {
        recordedSignals.withLock { $0 }
    }
}
