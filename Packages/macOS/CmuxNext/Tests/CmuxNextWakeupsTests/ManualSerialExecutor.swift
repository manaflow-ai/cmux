import Foundation

/// A serial executor that runs its jobs only when the test calls ``runJobs()``. The test decides
/// when the actor's next turn comes, as a busy main thread does in the app: a job that arrives
/// while the actor is busy waits until the test lets it run.
// Test-only executor; `jobs` is guarded by `lock` (jobs are enqueued from any thread).
nonisolated final class ManualSerialExecutor: SerialExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [UnownedJob] = []

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        lock.withLock { jobs.append(job) }
    }

    /// Runs the waiting jobs, and the jobs they enqueue on this executor, on the calling thread.
    func runJobs() {
        while let job = lock.withLock({ jobs.isEmpty ? nil : jobs.removeFirst() }) {
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }

    /// Waits (bounded) until a job waits for the actor's turn. Advancing a manual clock wakes a
    /// deadline's task on the cooperative pool; its next step toward the actor is this job.
    func waitForJob() async throws {
        for _ in 0..<20 where lock.withLock({ jobs.isEmpty }) { await Task.yield() }
        for _ in 0..<500 where lock.withLock({ jobs.isEmpty }) { try await Task.sleep(for: .milliseconds(5)) }
        // No job after the bound: running the executor now would test nothing, so the test fails here.
        if lock.withLock({ jobs.isEmpty }) { throw NoJob() }
    }

    /// `waitForJob` timed out: nothing was enqueued for the actor.
    struct NoJob: Error, CustomStringConvertible {
        var description: String { "no job reached the manual executor within 2.5 s" }
    }
}
