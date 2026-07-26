import CmuxFoundation
import Foundation

/// One configuration transaction's font-scale boundary.
///
/// Settings reload before the target is sampled, so a value imported from
/// cmux.json and the Ghostty config built in this transaction cannot diverge.
@MainActor
struct TerminalFontConfigurationReloadTransaction {
    let previousMagnificationPercent: Int
    let targetMagnificationPercent: Int

    var magnificationDidChange: Bool {
        previousMagnificationPercent
            != targetMagnificationPercent
    }

    static func prepare(
        appliedMagnificationPercent: Int,
        reloadSettings: @MainActor () -> Void,
        storedMagnificationPercent: @MainActor () -> Int
    ) -> Self {
        let previousMagnificationPercent =
            GlobalFontMagnification.clamp(
                appliedMagnificationPercent
            )
        reloadSettings()
        return Self(
            previousMagnificationPercent:
                previousMagnificationPercent,
            targetMagnificationPercent:
                GlobalFontMagnification.clamp(
                    storedMagnificationPercent()
                )
        )
    }
}

/// Runs post-config terminal font reconciliation in bounded main-run-loop
/// turns. Each work item may perform at most one native font mutation.
@MainActor
final class TerminalFontConfigurationReloadReconciler {
    typealias Work = @MainActor () -> Void
    typealias CaptureNextWork =
        @MainActor () -> ReconciliationWork?
    typealias Scheduler =
        @MainActor (@escaping @MainActor () -> Void) -> Void

    struct ReconciliationWork {
        let attempt: @MainActor () -> Bool
        let abandon: Work

        init(
            attempt: @escaping @MainActor () -> Bool,
            abandon: @escaping Work = {}
        ) {
            self.attempt = attempt
            self.abandon = abandon
        }
    }

    private final class WorkNode {
        let work: ReconciliationWork
        var attemptCount = 0
        var next: WorkNode?

        init(_ work: ReconciliationWork) {
            self.work = work
        }
    }

    private enum Phase {
        case idle
        case capturing
        case reconciling
    }

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
