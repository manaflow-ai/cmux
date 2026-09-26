import Dispatch
import Foundation
import Testing
@testable import CmuxGit

@Suite struct BoundedBlockingRunnerTests {
    @Test func returnsTheJobResultWhenItFinishesInTime() async {
        let runner = BoundedBlockingRunner(label: "test.bounded-runner.fast")

        let value = await runner.run(timeout: .seconds(30)) { _ in 42 }

        #expect(value == 42)
    }

    @Test func timeoutResumesTheCallerWhileTheJobIsStillBlocked() async {
        let runner = BoundedBlockingRunner(label: "test.bounded-runner.hung")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let clock = ContinuousClock()
        let start = clock.now

        let value = await runner.run(timeout: .milliseconds(100)) { _ -> Int? in
            release.wait()
            return 1
        }

        #expect(value == nil)
        #expect(clock.now - start < .seconds(10))
    }

    @Test func callsWhileAJobIsStuckReturnImmediatelyInsteadOfQueueing() async throws {
        let runner = BoundedBlockingRunner(label: "test.bounded-runner.busy")
        let release = DispatchSemaphore(value: 0)

        let first = await runner.run(timeout: .milliseconds(50)) { _ -> Int? in
            release.wait()
            return 1
        }
        let whileBusy = await runner.run(timeout: .seconds(30)) { _ in 2 }
        #expect(first == nil)
        #expect(whileBusy == nil)

        release.signal()
        var afterRelease: Int?
        for _ in 0..<200 where afterRelease == nil {
            afterRelease = await runner.run(timeout: .seconds(30)) { _ in 3 }
            if afterRelease == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(afterRelease == 3)
    }
}
