// Shared scaffolding for the JSONConfigStore test suites.

import Foundation

/// Re-applies the same external edit on a loop, bumping the file's modification
/// date each pass. The subscriber can finish registering just after the initial
/// value is yielded, so a single external write could land before the watcher is
/// armed; each re-touch produces a fresh DispatchSource event once it is. The
/// bytes are identical every pass, so this closes the readiness race without
/// weakening what the test asserts.
func retouchingWriter(payload: String, fileURL: URL) -> Task<Void, Never> {
    Task {
        var bump = Date()
        while !Task.isCancelled {
            try? Data(payload.utf8).write(to: fileURL)
            bump = bump.addingTimeInterval(1)
            try? FileManager.default.setAttributes([.modificationDate: bump], ofItemAtPath: fileURL.path)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// Awaits an observation task with timeout-backed cancellation.
func observedValues(_ observed: Task<[String], Never>) async -> [String] {
    await withTimeout(seconds: 8) {
        await withTaskCancellationHandler {
            await observed.value
        } onCancel: {
            observed.cancel()
        }
    }
}

/// Races async work against a timeout and returns the first cooperative result.
func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        for await result in group {
            if let result {
                group.cancelAll()
                return result
            }
            // Timeout sentinel: cancel the in-flight work so cooperative call
            // sites unwind and surface a partial value; the assertions that
            // follow then fail instead of the run wedging forever.
            group.cancelAll()
        }
        fatalError("timed out without producing a value")
    }
}
