import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// `IdleOwnerRestart` with a `Retry` (the quiet restart of a stale cmux-tui): while the owner is
/// busy it tries again on one bounded deadline at a time, a limited number of times, then only on
/// owner events; it restarts once, when idle, and never after `stop`.
struct IdleOwnerRestartRetryTests {
    /// The probe's answer and the calls, shared with the restart's closures.
    private final class Owner: Sendable {
        private let state = Mutex((idle: false, probes: 0, restarts: 0))
        var idle: Bool {
            get { state.withLock { $0.idle } }
            set { state.withLock { $0.idle = newValue } }
        }
        var probes: Int { state.withLock { $0.probes } }
        var restarts: Int { state.withLock { $0.restarts } }

        func probe() -> Bool {
            state.withLock { state -> Bool in
                state.probes += 1
                return state.idle
            }
        }
        func restart() -> Bool { state.withLock { $0.restarts += 1 }; return true }
    }

    private static func restart(_ owner: Owner, clock: ManualClock, retries: Int) -> IdleOwnerRestart {
        IdleOwnerRestart(isIdle: { owner.probe() },
                         retry: IdleOwnerRestart.Retry(interval: .seconds(60), count: retries, clock: clock)) { owner.restart() }
    }

    /// Bounded wait for the deadline's probe, which runs off this task.
    private static func probes(_ owner: Owner, reach count: Int) async {
        for _ in 0..<400 where owner.probes < count {
            try? await Task.sleep(for: .milliseconds(5))  // test harness poll of the timer task
        }
    }

    private static let clientLeft = DaemonEvent.client(name: "client-detached", payload: .null)

    @Test func itWaitsWhileBusyAndRestartsAtTheFirstQuietDeadline() async throws {
        let owner = Owner()
        let clock = ManualClock()
        let restart = Self.restart(owner, clock: clock, retries: 3)
        #expect(await restart.attempt() == .waiting)
        #expect(owner.restarts == 0)

        // Still busy at the first deadline: one more probe, and the next deadline.
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(60))
        await Self.probes(owner, reach: 2)
        #expect(owner.probes == 2)
        #expect(owner.restarts == 0)

        // Quiet by the second: it restarts, once.
        owner.idle = true
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(60))
        await Self.probes(owner, reach: 3)
        for _ in 0..<400 {
            if await restart.outcome != .waiting { break }
            try? await Task.sleep(for: .milliseconds(5))  // test harness poll of the timer task
        }
        #expect(await restart.outcome == .started)
        #expect(owner.restarts == 1)
        #expect(await restart.attempt() == .started)
        #expect(await restart.note(Self.clientLeft) == .started)
        #expect(owner.restarts == 1)
    }

    @Test func afterItsDeadlinesOnlyAnOwnerEventTriesAgain() async throws {
        let owner = Owner()
        let clock = ManualClock()
        let restart = Self.restart(owner, clock: clock, retries: 2)
        #expect(await restart.attempt() == .waiting)
        for step in 2...3 {
            try await clock.waitForSleeper()
            clock.advance(by: .seconds(60))
            await Self.probes(owner, reach: step)
        }
        #expect(owner.probes == 3)
        // The budget is spent: no deadline is armed, so time alone probes no more.
        clock.advance(by: .seconds(3600))
        try? await Task.sleep(for: .milliseconds(50))  // let a wrongly armed deadline show
        #expect(owner.probes == 3)

        // An event that may end the business (a client left) probes again; others do not.
        #expect(await restart.note(.client(name: "client-attached", payload: .null)) == .waiting)
        #expect(owner.probes == 3)
        owner.idle = true
        #expect(await restart.note(Self.clientLeft) == .started)
        #expect(owner.probes == 4)
        #expect(owner.restarts == 1)
    }

    @Test func stopEndsTheWait() async throws {
        let owner = Owner()
        let clock = ManualClock()
        let restart = Self.restart(owner, clock: clock, retries: 5)
        #expect(await restart.attempt() == .waiting)
        try await clock.waitForSleeper()
        await restart.stop()
        owner.idle = true
        clock.advance(by: .seconds(600))
        try? await Task.sleep(for: .milliseconds(50))  // let a wrongly kept deadline show
        #expect(await restart.note(Self.clientLeft) == .waiting)
        #expect(await restart.attempt() == .waiting)
        #expect(owner.probes == 1)
        #expect(owner.restarts == 0)
    }
}
