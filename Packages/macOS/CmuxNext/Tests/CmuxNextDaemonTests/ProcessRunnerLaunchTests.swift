import CmuxNextDaemon
import Foundation
import Testing

/// `ProcessRunner.run` (p02-threads-040): the child spawns on a `ProcessLauncher` queue, never the caller's actor or
/// the cooperative pool (Chromium's launcher thread, content/browser/child_process_launcher_helper.cc), and still
/// reports its status and output, its launch failure, and a cancel that comes while the launch is in flight.
@Suite(.timeLimit(.minutes(1)))
struct ProcessRunnerLaunchTests {
    @MainActor
    @Test func aRunFromTheMainActorFeedsStdinAndReturnsItsStatusAndOutput() async throws {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "/bin/cat; exit 4"],
                                                 environment: [:], stdin: Data("key".utf8), timeout: .seconds(20),
                                                 clock: ContinuousClock())
        #expect(result.status == 4)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "key")
    }

    @Test func aMissingProgramThrowsLaunchFailed() async {
        do {
            _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/no/such/program"), arguments: [],
                                            environment: [:], timeout: .seconds(5), clock: ContinuousClock())
            Issue.record("a missing program ran")
        } catch let error as DaemonError {
            #expect(error == .launchFailed("could not start /no/such/program"))
        } catch {
            Issue.record("a missing program failed with \(error)")
        }
    }

    /// The cancel lands right after the start, mostly while the spawn is still queued on the launcher: the kill
    /// after the launch reaches the child, so the run ends now, not when `sleep 30` exits.
    @Test func aCancelDuringTheLaunchStillKillsTheChild() async {
        let clock = ContinuousClock()
        let started = clock.now
        let run = Task {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                        environment: [:], timeout: .seconds(50), clock: clock)
        }
        run.cancel()
        switch await run.result {
        case .success(let result): #expect(result.status != 0, "a cancelled run ended on its own")
        case .failure: break
        }
        #expect(started.duration(to: clock.now) < .seconds(15), "the cancelled child ran on")
    }
}
