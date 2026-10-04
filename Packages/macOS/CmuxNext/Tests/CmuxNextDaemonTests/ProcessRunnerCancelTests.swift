@testable import CmuxNextDaemon
import Foundation
import Testing

/// A cancelled caller ends the child at once instead of waiting for its
/// own exit or the deadline.
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
}
