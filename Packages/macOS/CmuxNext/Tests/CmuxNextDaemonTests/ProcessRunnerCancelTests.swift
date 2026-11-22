@testable import CmuxNextDaemon
import Foundation
import Synchronization
import Testing

/// A cancelled caller ends the child at once instead of waiting for its
/// own exit or the deadline; no signal ever goes to a child that does not run.
@Suite struct ProcessRunnerCancelTests {
    @Test func cancellingTheCallerKillsTheChild() async throws {
        let started = ContinuousClock.now
        let run = Task {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"],
                                        environment: nil, timeout: .seconds(60), clock: ContinuousClock())
        }
        try await Task.sleep(for: .milliseconds(300))
        run.cancel()
        _ = try? await run.value
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// The timeout and cancel paths both kill through `ProcessBox.kill`: before
    /// launch the pid is 0 (our own process group) and after exit it may be
    /// reused, so neither may send a signal.
    @Test func aChildThatDoesNotRunGetsNoSignal() async throws {
        let sent = Mutex<[pid_t]>([])
        let record: @Sendable (pid_t, Int32) -> Void = { pid, _ in sent.withLock { $0.append(pid) } }
        let unlaunched = Process()
        unlaunched.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        ProcessBox(unlaunched, signal: record).kill()

        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        ProcessBox(finished, signal: record).kill()
        #expect(sent.withLock { $0 }.isEmpty)
    }
}
