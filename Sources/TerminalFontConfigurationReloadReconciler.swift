import Foundation

/// Runs post-config terminal font reconciliation in bounded main-run-loop
/// turns. Each work item may perform at most one native font mutation.
@MainActor
final class TerminalFontConfigurationReloadReconciler {
    typealias Work = @MainActor () -> Void
    typealias CaptureNextWork =
        @MainActor () -> ReconciliationWork?
    typealias Scheduler =
        @MainActor @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    nonisolated static let defaultMaximumSurfaceVisitsPerDrain = 8
    nonisolated static let defaultMaximumAttemptsPerWork = 3

    private let maximumSurfaceVisitsPerDrain: Int
    private let maximumAttemptsPerWork: Int
    private let schedule: Scheduler
    private var phase = Phase.idle
    private var captureNextWork: CaptureNextWork?
    private var applyConfiguration: Work?
    private var capturedWorkHead: WorkNode?
    private var capturedWorkTail: WorkNode?
    private var activeWork: WorkNode?
    private var retryWorkHead: WorkNode?
    private var retryWorkTail: WorkNode?
    private var completion: Work?
    private var isDrainScheduled = false

    nonisolated init(
        maximumSurfaceVisitsPerDrain: Int =
            defaultMaximumSurfaceVisitsPerDrain,
        maximumAttemptsPerWork: Int =
            defaultMaximumAttemptsPerWork,
        schedule: @escaping Scheduler = { action in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    action()
                }
            }
        }
    ) {
        precondition(maximumSurfaceVisitsPerDrain > 0)
        precondition(maximumAttemptsPerWork > 0)
        self.maximumSurfaceVisitsPerDrain =
            maximumSurfaceVisitsPerDrain
        self.maximumAttemptsPerWork = maximumAttemptsPerWork
        self.schedule = schedule
    }

    /// Captures pre-config state and reconciles post-config state in separately
    /// bounded turns. Configuration is applied only after traversal reaches its
    /// end, so every captured surface observes one coherent old configuration.
    func reconcileIncrementally(
        captureNextWork: @escaping CaptureNextWork,
        applyConfiguration: @escaping Work,
        completion: @escaping Work
    ) {
        precondition(
            !isReconciling,
            "Configuration font reconciliation must remain serialized"
        )
        phase = .capturing
        self.captureNextWork = captureNextWork
        self.applyConfiguration = applyConfiguration
        self.completion = completion
        scheduleDrain()
    }

    var isReconciling: Bool {
        phase != .idle
    }

    /// Queues work that must run after the configuration captured by the
    /// current transaction is applied.
    ///
    /// Capture itself keeps a fixed registry endpoint. Terminal runtimes
    /// requested after that endpoint was taken use this queue instead, so
    /// sustained terminal creation cannot postpone configuration application.
    @discardableResult
    func enqueuePostConfigurationWork(
        _ work: ReconciliationWork
    ) -> Bool {
        guard phase == .capturing else { return false }
        appendCapturedWork(work)
        return true
    }

    private func scheduleDrain() {
        guard !isDrainScheduled else { return }
        isDrainScheduled = true
        schedule { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        isDrainScheduled = false
        switch phase {
        case .idle:
            return
        case .capturing:
            drainCapture()
        case .reconciling:
            drainReconciliation()
        }
    }

    private func drainCapture() {
        guard let captureNextWork else {
            preconditionFailure(
                "Capturing reconciliation requires a source"
            )
        }
        var visits = 0
        while visits < maximumSurfaceVisitsPerDrain {
            guard let work = captureNextWork() else {
                finishCapture()
                return
            }
            appendCapturedWork(work)
            visits += 1
        }
        scheduleDrain()
    }

    private func finishCapture() {
        self.captureNextWork = nil
        let applyConfiguration = self.applyConfiguration
        self.applyConfiguration = nil
        applyConfiguration?()
        phase = .reconciling
        activeWork = capturedWorkHead
        capturedWorkHead = nil
        capturedWorkTail = nil
        guard activeWork != nil else {
            finish()
            return
        }
        scheduleDrain()
    }

    private func drainReconciliation() {
        var visits = 0
        while visits < maximumSurfaceVisitsPerDrain,
              let node = activeWork {
            activeWork = node.next
            node.next = nil
            node.attemptCount += 1
            if !node.work.attempt() {
                if node.attemptCount < maximumAttemptsPerWork {
                    appendRetryWork(node)
                } else {
                    node.work.abandon()
                }
            }
            visits += 1
        }
        if activeWork != nil {
            scheduleDrain()
            return
        }

        if let retryWorkHead {
            activeWork = retryWorkHead
            self.retryWorkHead = nil
            retryWorkTail = nil
            scheduleDrain()
            return
        }
        finish()
    }

    private func appendCapturedWork(
        _ work: ReconciliationWork
    ) {
        let node = WorkNode(work)
        if let capturedWorkTail {
            capturedWorkTail.next = node
        } else {
            capturedWorkHead = node
        }
        capturedWorkTail = node
    }

    private func appendRetryWork(_ node: WorkNode) {
        if let retryWorkTail {
            retryWorkTail.next = node
        } else {
            retryWorkHead = node
        }
        retryWorkTail = node
    }

    private func finish() {
        phase = .idle
        captureNextWork = nil
        applyConfiguration = nil
        capturedWorkHead = nil
        capturedWorkTail = nil
        activeWork = nil
        retryWorkHead = nil
        retryWorkTail = nil
        let completion = self.completion
        self.completion = nil
        completion?()
    }
}
