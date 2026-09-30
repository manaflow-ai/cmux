import Foundation
import Synchronization
import Testing
@testable import CmuxNextControl

/// A wait that ignores cancellation (like a continuation parked on another
/// process's reply) until the test releases it.
private final class Parked: Sendable {
    private let waiter = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let released = Mutex(false)

    func wait() async {
        await withCheckedContinuation { continuation in
            let now = released.withLock { released -> Bool in released }
            if now { continuation.resume() } else { waiter.withLock { $0 = continuation } }
        }
    }

    func release() {
        released.withLock { $0 = true }
        waiter.withLock { waiter in
            waiter?.resume()
            waiter = nil
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct CompatDeadlineTests {
    /// Regression: `CompatDeadline` raced the body in a task group, which
    /// waits for every child on exit, so a body that ignores cancellation
    /// held the CLI caller until the body finished: the deadline was a hang.
    @Test func deadlineAnswersWithoutWaitingForAnUncancellableBody() async throws {
        let parked = Parked()
        let backstop = Task { // bounds the old hang so the run reports it instead of stalling
            try? await Task.sleep(for: .seconds(2))
            parked.release()
        }
        defer { backstop.cancel() }
        let started = ContinuousClock.now
        await #expect(throws: ControlError.self) {
            try await CompatDeadline.run("parked", within: .milliseconds(50)) {
                await parked.wait()
                return 1
            }
        }
        let elapsed = started.duration(to: .now)
        parked.release()
        #expect(elapsed < .seconds(1))
    }

    /// Regression: v1 plain-text lines ran with no overall deadline.
    @Test func v1LineAnswersWithinTheRequestDeadline() async throws {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(),
                                   configuration: .init(requestDeadline: .milliseconds(50)))
        let parked = Parked()
        let backstop = Task {
            try? await Task.sleep(for: .seconds(2))
            parked.release()
        }
        defer { backstop.cancel() }
        router.registerV1 { _ in
            await parked.wait()
            return "late"
        }
        let started = ContinuousClock.now
        let reply = await router.response(forLine: "notify hello")
        let elapsed = started.duration(to: .now)
        parked.release()
        #expect(reply.hasPrefix("ERROR"))
        #expect(elapsed < .seconds(1))
    }
}
