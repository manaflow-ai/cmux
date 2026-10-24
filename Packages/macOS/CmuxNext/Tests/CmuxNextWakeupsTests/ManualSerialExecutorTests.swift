import CmuxNextWakeupsTestSupport
import Testing

/// The shared manual serial executor: a job waits until the test runs it, and a wait for a job
/// returns only once one is enqueued. DemandTimerTests' red guards depend on this: a `waitForJob`
/// that returned before the deadline's hop arrived would make `runJobs()` run nothing, and a guard
/// that expects "the replaced action did not run" would pass on the buggy code.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ManualSerialExecutorTests {
    @Test func aJobRunsOnlyWhenTheTestRunsTheJobs() async throws {
        let ran = Flag()
        let hop = Task { await ExecutorTestActor.shared.run { ran.set() } }
        try await ExecutorTestActor.executor.waitForJob()
        #expect(!ran.isSet, "a job ran before the test gave the actor its turn")
        #expect(ExecutorTestActor.executor.runJobs() == 1)
        #expect(ExecutorTestActor.executor.runJobs() == 0)
        await hop.value
        #expect(ran.isSet)
    }

    /// After `waitForJob` returns, `runJobs` has a job to run: the wait ended because the job is
    /// there, not early.
    @Test func waitForJobReturnsOnlyOnceAJobWaits() async throws {
        let ran = Flag()
        let waiting = Task { try await ExecutorTestActor.executor.waitForJob() }
        let hop = Task { await ExecutorTestActor.shared.run { ran.set() } }
        try await waiting.value
        ExecutorTestActor.executor.runJobs()
        #expect(ran.isSet, "waitForJob returned while no job waited")
        await hop.value
    }

    @Test func cancellingAWaitForAJobEndsIt() async throws {
        let waiting = Task { try await ExecutorTestActor.executor.waitForJob() }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}
