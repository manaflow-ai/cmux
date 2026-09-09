import Foundation
import Testing
@testable import CmuxHive

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HiveMirrorWorkspaceReadinessTests {
    @Test(arguments: [false, true])
    func reconciledWorkspaceArrivesBeforeOrDuringWait(alreadyReady: Bool) async throws {
        let readiness = HiveMirrorWorkspaceReadiness()
        let deadline = AsyncStream<Void>.makeStream()
        let waiting = AsyncStream<Void>.makeStream()
        defer { readiness.finish(); deadline.continuation.finish(); waiting.continuation.finish() }
        let id = UUID()
        readiness.publish(UUID())
        readiness.publish(nil)
        if alreadyReady { readiness.publish(id) }
        let task = Task {
            await readiness.wait {
                waiting.continuation.yield(())
                for await _ in deadline.stream { break }
            }
        }
        var started = waiting.stream.makeAsyncIterator()
        _ = try #require(await started.next())
        if !alreadyReady { readiness.publish(id) }
        #expect(await task.value == id)
    }

    @Test func teardownEndsTheWaitWithoutRequiringADeadline() async {
        let readiness = HiveMirrorWorkspaceReadiness()
        let deadline = AsyncStream<Void>.makeStream()
        defer { deadline.continuation.finish() }
        readiness.finish()
        #expect(await readiness.wait { for await _ in deadline.stream { break } } == nil)
    }

    @Test func deadlineEndsAnEmptyAttachment() async {
        let readiness = HiveMirrorWorkspaceReadiness()
        defer { readiness.finish() }
        #expect(await readiness.wait(timeout: {}) == nil)
    }
}
