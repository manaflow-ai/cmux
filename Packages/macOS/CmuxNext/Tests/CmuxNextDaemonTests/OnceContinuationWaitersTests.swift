import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The daemon module's waits on CmuxSafeConcurrency's OnceContinuation: each still answers
/// as its raw continuation did, whichever of the producer and the waiter comes first.
@Suite(.timeLimit(.minutes(1))) struct OnceContinuationWaitersTests {
    @Test func anIdleWaitReturnsWhenTheLastTicketCloses() async {
        let scope = DaemonCommandScope.automation(idempotencyKey: nil)
        let ticket = scope.begin(label: "test")
        #expect(!scope.isIdle)
        let idle = Task { await scope.waitUntilIdle() }
        scope.end(ticket)
        await idle.value
        #expect(scope.isIdle)
    }

    @Test func anIdleWaitWithNoTicketReturnsAtOnce() async {
        let scope = DaemonCommandScope.automation(idempotencyKey: nil)
        await scope.waitUntilIdle()
        #expect(scope.isIdle)
    }

    @Test func aParkedTerminalReadGetsTheNextEvent() async {
        let queue = TerminalEventQueue(recorder: nil)
        let read = Task { await queue.next() }
        let event = TerminalChannelEvent.output(Data([1, 2, 3]), colors: nil)
        queue.push(event)
        #expect(await read.value == event)
    }

    @Test func aParkedTerminalReadGetsNilAtTheEnd() async {
        let queue = TerminalEventQueue(recorder: nil)
        let read = Task { await queue.next() }
        queue.finish()
        #expect(await read.value == nil)
    }

    @Test func anExitWaitForAGoneProcessIsTrue() async {
        // No process has this pid: the wait sees it gone at once.
        let exited = await ProcessExit.exitEvent(pid: Int32.max, within: .seconds(30), clock: ContinuousClock())
        #expect(exited)
    }

    @Test func anExitWaitForALiveProcessIsFalseAtItsDeadline() async {
        // The test process outlives the wait.
        let exited = await ProcessExit.exitEvent(pid: getpid(), within: .milliseconds(20), clock: ContinuousClock())
        #expect(!exited)
    }
}
