import Foundation
import Testing
@testable import CmuxNextDaemon

/// The daemon module's parked waiters on `OnceContinuation` (p10-stability-087): each one still
/// wakes on its event, before or after it parked, and a second wake is a no-op, never a trap.
struct OnceContinuationWaitersTests {
    private static func response(_ text: String) -> LineTransport.Response {
        LineTransport.Response(line: Data(text.utf8), eventBarrier: 7)
    }

    @Test func aReplySlotResolvedBeforeTheAwaitAnswersAtOnce() async throws {
        let slot = ReplySlot()
        slot.resolve(.success(Self.response("first")))
        let reply = try await slot.value()
        #expect(reply.line == Data("first".utf8))
    }

    @Test func aReplySlotKeepsItsFirstResolution() async throws {
        let slot = ReplySlot()
        let waiting = Task { try await slot.value() }
        await Task.yield()
        slot.resolve(.success(Self.response("first")))
        slot.resolve(.failure(DaemonError.notConnected))
        slot.resolve(.success(Self.response("second")))
        let reply = try await waiting.value
        #expect(reply.line == Data("first".utf8))
        #expect(reply.eventBarrier == 7)
    }

    @Test func aReplySlotFailureReachesTheWaiter() async {
        let slot = ReplySlot()
        let waiting = Task { try await slot.value() }
        await Task.yield()
        slot.resolve(.failure(DaemonError.notConnected))
        await #expect(throws: DaemonError.self) { try await waiting.value }
    }

    @Test func aParkedTerminalReadEndsWhenTheConsumerCancels() async {
        let queue = TerminalEventQueue()
        let read = Task { await queue.next() }
        await Task.yield()
        queue.cancel()
        #expect(await read.value == nil)
        // A read after the end answers at once.
        #expect(await queue.next() == nil)
    }

    @Test func aParkedTerminalReadGetsTheFinalEvent() async {
        let queue = TerminalEventQueue()
        let read = Task { await queue.next() }
        await Task.yield()
        let last = TerminalChannelEvent.output(Data("bye".utf8), colors: nil)
        queue.finish(last)
        #expect(await read.value == last)
    }

    @Test func waitUntilIdleWakesWhenTheLastTicketCloses() async {
        let scope = DaemonCommandScope()
        await scope.waitUntilIdle()
        let first = scope.begin(label: "a")
        let second = scope.begin(label: "b")
        let idle = Task { await scope.waitUntilIdle() }
        scope.end(first)
        #expect(!scope.isIdle)
        scope.end(second)
        await idle.value
        #expect(scope.isIdle)
    }

    @Test func anExitWaitForAnExitingProcessSeesTheExit() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.2"]
        try process.run()
        // Alive when the wait registers, so the kernel's exit event answers it.
        let exited = await ProcessExit.exitEvent(pid: process.processIdentifier, within: .seconds(30),
                                                 clock: ContinuousClock())
        #expect(exited)
    }

    @Test func anExitWaitForALiveProcessEndsAtItsDeadline() async {
        let exited = await ProcessExit.exitEvent(pid: getpid(), within: .milliseconds(20), clock: ContinuousClock())
        #expect(!exited)
    }
}
