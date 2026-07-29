import Darwin

/// Serializes cancellation with suspended process-group launch.
actor CommandCancellationLatch {
    private var isCancelled = false
    private var isFinished = false
    private var notification: (@Sendable () -> Void)?
    private var action: (@Sendable () -> Void)?

    /// Installs the result-side cancellation notification before launch.
    /// Cancellation that arrived first invokes it immediately.
    func notifyOnCancel(_ notification: @escaping @Sendable () -> Void) {
        guard !isFinished else { return }
        if isCancelled {
            notification()
        } else {
            self.notification = notification
        }
    }

    /// Returns whether a blocking spawn should begin.
    func mayLaunch() -> Bool {
        !isFinished && !isCancelled
    }

    /// Registers a suspended child after spawn. Cancellation that arrived
    /// during spawn terminates it before the caller can resume it.
    func register(
        processIdentifier: pid_t,
        onCancel: @escaping @Sendable (pid_t) -> Void
    ) -> Bool {
        guard !isFinished, !isCancelled else {
            onCancel(processIdentifier)
            return false
        }
        action = {
            onCancel(processIdentifier)
        }
        return true
    }

    /// Resumes a suspended launch from the same actor that owns cancellation.
    /// `nil` means cancellation already owns the process.
    func resume(_ processIdentifier: pid_t) -> Int32? {
        guard !isFinished, !isCancelled else { return nil }
        guard Darwin.kill(processIdentifier, SIGCONT) == 0 else {
            return errno
        }
        return 0
    }

    func cancel() {
        guard !isFinished else { return }
        isCancelled = true
        let notification = self.notification
        self.notification = nil
        let action = self.action
        self.action = nil
        notification?()
        action?()
    }

    func clear() {
        isFinished = true
        notification = nil
        action = nil
    }
}
