import Dispatch
import Foundation
import Testing
@testable import CmuxGit

@Suite struct BoundedBlockingRunnerTests {
    @Test func returnsTheJobResultWhenItFinishesInTime() async {
        let runner = BoundedBlockingRunner(label: "test.bounded-runner.fast")

        let outcome = await runner.run(timeout: .seconds(30)) { _ in 42 }

        #expect(outcome == .finished(42))
    }

    @Test func timeoutResumesTheCallerWhileTheJobIsStillBlocked() async {
        let runner = BoundedBlockingRunner(label: "test.bounded-runner.hung")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let clock = ContinuousClock()
        let start = clock.now

        let outcome = await runner.run(timeout: .milliseconds(100)) { _ -> Int in
            release.wait()
            return 1
        }

        #expect(outcome == .timedOut)
        #expect(clock.now - start < .seconds(10))
    }

    @Test func callsWhileAJobIsStuckReturnImmediatelyInsteadOfQueueing() async throws {
        let runner = BoundedBlockingRunner(label: "test.bounded-runner.busy")
        let release = DispatchSemaphore(value: 0)

        // A generous timeout so a slow CI queue still starts the job before
        // the deadline; the job then blocks until released.
        let first = await runner.run(timeout: .milliseconds(500)) { _ -> Int in
            release.wait()
            return 1
        }
        #expect(runner.isBusy)
        let whileBusy = await runner.run(timeout: .seconds(30)) { _ in 2 }
        #expect(first == .timedOut)
        #expect(whileBusy == .busy)

        release.signal()
        for _ in 0..<500 where runner.isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        let afterRelease = await runner.run(timeout: .seconds(30)) { _ in 3 }
        #expect(afterRelease == .finished(3))
    }

    @Test func anExpiredDeadlineNeverStartsTheJob() async throws {
        let runner = BoundedBlockingRunner(label: "test.bounded-runner.expired")
        let started = StartedFlag()

        let outcome = await runner.run(timeout: .zero) { _ -> Int in
            started.set()
            return 1
        }

        #expect(outcome == .timedOut)
        for _ in 0..<500 where runner.isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!started.value)
    }
}

/// A thread-safe flag for the job closure above.
private final class StartedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
