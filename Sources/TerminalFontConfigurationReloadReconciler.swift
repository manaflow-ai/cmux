import Foundation

/// Runs post-config terminal font reconciliation in bounded main-run-loop
/// turns. Each work item may perform at most one native font mutation.
@MainActor
final class TerminalFontConfigurationReloadReconciler {
    typealias Work = @MainActor () -> Void
    typealias Scheduler =
        @MainActor (@escaping @MainActor () -> Void) -> Void

    nonisolated static let defaultMaximumSurfaceVisitsPerDrain = 8

    private let maximumSurfaceVisitsPerDrain: Int
    private let schedule: Scheduler
    private var work: [Work] = []
    private var workHead = 0
    private var completion: Work?
    private var isDrainScheduled = false

    nonisolated init(
        maximumSurfaceVisitsPerDrain: Int =
            defaultMaximumSurfaceVisitsPerDrain,
        schedule: @escaping Scheduler = { action in
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    action()
                }
            }
        }
    ) {
        precondition(maximumSurfaceVisitsPerDrain > 0)
        self.maximumSurfaceVisitsPerDrain =
            maximumSurfaceVisitsPerDrain
        self.schedule = schedule
    }

    func reconcile(
        _ work: [Work],
        completion: @escaping Work
    ) {
        precondition(
            !isReconciling,
            "Configuration font reconciliation must remain serialized"
        )
        guard !work.isEmpty else {
            completion()
            return
        }
        self.work = work
        workHead = 0
        self.completion = completion
        scheduleDrain()
    }

    var isReconciling: Bool {
        workHead < work.count || completion != nil
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
        let end = min(
            work.count,
            workHead + maximumSurfaceVisitsPerDrain
        )
        while workHead < end {
            let action = work[workHead]
            workHead += 1
            action()
        }
        guard workHead == work.count else {
            scheduleDrain()
            return
        }

        work.removeAll(keepingCapacity: false)
        workHead = 0
        let completion = self.completion
        self.completion = nil
        completion?()
    }
}
