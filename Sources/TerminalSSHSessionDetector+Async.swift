import Foundation

extension TerminalSSHSessionDetector {
    static let defaultDetectionTimeout: TimeInterval = 0.25

    /// Resolves an ad-hoc SSH session without making the caller wait for a
    /// process that may be stuck reading another process's memory.
    ///
    /// The synchronous detector runs on a detached worker. The deadline task
    /// completes the request independently; a worker that is wedged in
    /// `KERN_PROCARGS2` is intentionally abandoned and its late result is
    /// ignored.
    static func detectAsync(
        forTTY ttyName: String,
        timeout: TimeInterval = defaultDetectionTimeout,
        detector: @escaping @Sendable (String) -> DetectedSSHSession? = { tty in
            detect(forTTY: tty)
        }
    ) async -> DetectedSSHSession? {
        let gate = TerminalSSHSessionDetectionTimeoutGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let worker = Task.detached(priority: .utility) {
                    await gate.finish(detector(ttyName))
                }
                let timeoutTask = Task.detached(priority: .utility) {
                    let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    await gate.finish(nil)
                }
                Task {
                    await gate.install(
                        continuation: continuation,
                        worker: worker,
                        timeoutTask: timeoutTask
                    )
                }
            }
        } onCancel: {
            Task { await gate.finish(nil) }
        }
    }
}
