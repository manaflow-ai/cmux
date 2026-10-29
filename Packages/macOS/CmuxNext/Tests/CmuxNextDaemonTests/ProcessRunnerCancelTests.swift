@testable import CmuxNextDaemon
import Foundation
import Testing

/// `ProcessRunner.run` spawns its child off the cooperative pool (p02-threads 047-052) and still treats a cancel
/// as a cancel: the child is killed and reaped, and the run never reports "could not start" for a child that
/// started. The waiter resumes only at the child's exit or a failed launch, never at the cancel.
@Suite(.timeLimit(.minutes(1))) struct ProcessRunnerCancelTests {
    /// Each child sleeps 30 s: five that were not killed would take past the time limit, so the limit proves
    /// every one was killed and reaped.
    @Test func aCancelledRunKillsItsChildAndNeverReportsALaunchFailure() async throws {
        for _ in 0..<5 {
            let run = Task {
                try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: nil,
                                            timeout: .seconds(120), clock: ContinuousClock())
            }
            run.cancel()
            do {
                // The killed child's status can win the race against the cancelled deadline: that is a reap too.
                let result = try await run.value
                #expect(result.status != 0)
            } catch is CancellationError {
            } catch {
                Issue.record("a cancelled run threw \(error)")
            }
        }
    }

    @Test func aMissingExecutableIsALaunchFailure() async throws {
        await #expect(throws: DaemonError.self) {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/nonexistent/cmux-test-tool"), arguments: [], environment: nil,
                                        timeout: .seconds(10), clock: ContinuousClock())
        }
    }
}
