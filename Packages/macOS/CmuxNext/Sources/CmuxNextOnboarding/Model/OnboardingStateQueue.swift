public import Foundation
import os

/// The one writer of the onboarding state file: every read and write runs
/// off the main thread, one after another in the order they were asked
/// for, so the launch decision, progress, Done and Continue Setup never
/// interleave their read-modify-write steps.
@MainActor
public final class OnboardingStateQueue {
    public let file: OnboardingStateFile
    /// The last queued operation; each new one waits for it.
    private var tail: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "onboarding")

    public init(file: OnboardingStateFile) {
        self.file = file
    }

    /// Queues a write; a failure is logged with `label`.
    public func write(_ label: String, _ work: @escaping @Sendable (OnboardingStateFile) throws -> Void) {
        let previous = tail, file = file, logger = logger
        // task-owner: the queue's chain; each operation is one small file write
        tail = Task.detached {
            await previous?.value
            do { try work(file) } catch { logger.error("\(label, privacy: .public): \(String(describing: error), privacy: .public)") }
        }
    }

    /// Queues an operation whose result the caller waits for (it may also write).
    public func perform<Result: Sendable>(_ work: @escaping @Sendable (OnboardingStateFile) -> Result) async -> Result {
        let previous = tail, file = file
        // task-owner: the queue's chain; one small file read (and write)
        let operation = Task.detached { () -> Result in
            await previous?.value
            return work(file)
        }
        tail = Task.detached { _ = await operation.value }
        return await operation.value
    }

    /// Waits until every queued operation ran.
    public func drain() async {
        await tail?.value
    }
}
