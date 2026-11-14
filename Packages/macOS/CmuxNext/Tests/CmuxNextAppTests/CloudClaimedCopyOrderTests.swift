import CmuxNextCloud
@testable import CmuxNextCloudCredentials
import Foundation
import Testing

/// A claimed machine's login copy (cmux#39382) is registered with Rust (`warm-spare` with `claimed`) before a start
/// onto that machine asks Rust's `wait-copy`. Unordered, a fast dial reached `wait-copy` before the registration landed:
/// the wait returned at once, both read "no login" and both installed it.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct CloudClaimedCopyOrderTests {
    /// A registration held until the test opens it: Rust's claim answer arriving late.
    @MainActor final class Gate {
        var opened = false, waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
        func open() { opened = true; for waiter in waiters { waiter.resume() }; waiters = [] }
    }

    /// What happened, in order.
    @MainActor final class Log { var lines: [String] = [], done = false }

    @Test func aStartWaitsForADelayedRegistrationBeforeItsWaitCopy() async {
        let claims = CloudClaimedCopyRegistrations(), gate = Gate(), log = Log()
        let registration = claims.register("vm_0123456789abcdefghij") { await gate.wait(); log.lines.append("registered"); return true }
        let start = Task { @MainActor in
            await claims.registered("vm_0123456789abcdefghij")
            log.lines.append("wait-copy")
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(log.lines.isEmpty) // the start is still held: Rust has not answered the claim
        gate.open()
        #expect(await registration.value)
        await start.value
        #expect(log.lines == ["registered", "wait-copy"])
        // Answered: a later start onto it, and one onto a machine with no claim, go on at once.
        await claims.registered("vm_0123456789abcdefghij")
        await claims.registered("vm_ffffffffffffffffffff")
        #expect(claims.pendingCount == 0)
    }

    @Test func aSecondClaimOfOneMachineIsWaitedOnToo() async {
        let claims = CloudClaimedCopyRegistrations(), first = Gate(), second = Gate(), log = Log()
        let one = claims.register("vm_0123456789abcdefghij") { await first.wait(); return 1 }
        let two = claims.register("vm_0123456789abcdefghij") { await second.wait(); return 2 }
        let start = Task { @MainActor in await claims.registered("vm_0123456789abcdefghij"); log.done = true }
        first.open()
        _ = await one.value
        for _ in 0..<20 { await Task.yield() }
        #expect(!log.done) // the second registration has not answered yet
        second.open()
        _ = await two.value
        await start.value
        #expect(log.done && claims.pendingCount == 0)
    }
}
