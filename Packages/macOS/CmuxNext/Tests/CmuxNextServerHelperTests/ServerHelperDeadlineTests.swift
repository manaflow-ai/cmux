import CmuxNextServerHelper
import Foundation
import Testing

struct ServerHelperDeadlineTests {
    @Test func aFastOperationReturnsItsValue() async throws {
        let value = try await ServerHelperDeadline.run(limit: .seconds(30), clock: ContinuousClock(), operation: { 7 }, onTimeout: {})
        #expect(value == 7)
    }

    @Test func aHungChildIsKilledAtTheLimit() async {
        let runner = ProcessFixRunner(limit: .milliseconds(200))
        let start = ContinuousClock.now
        await #expect(throws: ServerHelperTimedOut.self) {
            _ = try await runner.run(URL(filePath: "/bin/sleep"), ["30"])
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func aFinishedChildReportsItsStatusAndOutput() async throws {
        let result = try await ProcessFixRunner(limit: .seconds(10)).run(URL(filePath: "/bin/echo"), ["AC Power:"])
        #expect(result.status == 0)
        #expect(result.output == "AC Power:\n")
    }

    @Test func aTimeoutEndsTheOperationThroughOnTimeout() async {
        let gate = Gate()
        await #expect(throws: ServerHelperTimedOut.self) {
            _ = try await ServerHelperDeadline.run(limit: .milliseconds(50), clock: ContinuousClock(), operation: {
                await gate.wait()
                return 1
            }, onTimeout: { gate.open() })
        }
    }

    @Test func theHelperReportsAPmsetTimeout() async {
        let service = ServerHelperService(runner: HangingRunner(), priors: MemoryFixPriorStore())
        let reply: String? = await withCheckedContinuation { c in service.apply(fixID: "pmset.ac.sleep.0") { c.resume(returning: $0) } }
        #expect(reply == "pmset timed out")
    }
}

/// A runner whose every run times out.
private struct HangingRunner: ServerFixRunner {
    func run(_ executable: URL, _ arguments: [String]) async throws -> FixRunResult {
        throw ServerHelperTimedOut()
    }
}

/// A one-shot latch the timeout opens.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if opened { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }
}
