import Foundation

/// Owns the one-shot result of a bounded SSH process lookup.
actor TerminalSSHSessionDetectionTimeoutGate {
    private var completed = false
    private var hasPendingResult = false
    private var pendingResult: DetectedSSHSession?
    private var continuation: CheckedContinuation<DetectedSSHSession?, Never>?
    private var worker: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func install(
        continuation: CheckedContinuation<DetectedSSHSession?, Never>,
        worker: Task<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) {
        guard !completed else {
            worker.cancel()
            timeoutTask.cancel()
            continuation.resume(
                returning: hasPendingResult ? pendingResult : nil
            )
            return
        }
        self.continuation = continuation
        self.worker = worker
        self.timeoutTask = timeoutTask
    }

    func finish(_ result: DetectedSSHSession?) {
        guard !completed else { return }
        completed = true
        worker?.cancel()
        timeoutTask?.cancel()
        if let continuation {
            continuation.resume(returning: result)
        } else {
            hasPendingResult = true
            pendingResult = result
        }
        self.continuation = nil
        worker = nil
        timeoutTask = nil
    }
}
