import CmuxNextCompat
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextDaemon

/// An owner that stays alive but never answers restarts without the confirm of "Restart cmux-tui"
/// (`UnresponsiveOwnerWatch`): only after two stuck ensures in a row over 30 s, never for an owner
/// that refuses at its connection limit (`server.busy`: it answers), and once per owner process.
struct UnresponsiveOwnerWatchTests {
    /// A value the watch's closures share with the test.
    private final class Shared<Value: Sendable>: Sendable {
        private let value: Mutex<Value>
        init(_ value: Value) { self.value = Mutex(value) }
        var current: Value {
            get { value.withLock { $0 } }
            set { value.withLock { $0 = newValue } }
        }
    }

    /// Bounded wait for the watch's replace task (the window's deadline runs off this task).
    private static func replaces(_ watch: UnresponsiveOwnerWatch, reach count: Int) async {
        for _ in 0..<400 where watch.replaceCount < count {
            try? await Task.sleep(for: .milliseconds(5))  // test harness poll of the timer task
        }
    }

    /// The replace as ``DaemonRecovery`` runs it: it claims, and replaces when the claim says yes.
    private static let claiming: @Sendable (_ claim: @escaping @Sendable () -> Bool) async -> Bool = { claim in claim() }

    private static func stuckEnsure() -> DaemonError {
        .launchFailed(#"exit 3: {"code":"server.unavailable","message":"m","details":{},"retryable":false}"#)
    }

    @Test func ensureOutcomesReadAsTheWatchNeeds() {
        let busy = DaemonError.launchFailed(#"exit 3: {"code":"server.busy","message":"m","details":{},"retryable":false}"#)
        let spawn = DaemonError.launchFailed(#"exit 3: {"code":"server.spawn_failed","message":"m","details":{},"retryable":false}"#)
        #expect(UnresponsiveOwnerWatch.Ensure(nil, pid: 7) == .ready(pid: 7))
        #expect(UnresponsiveOwnerWatch.Ensure(DaemonError.sessionRestoreTimedOut("slow"), pid: nil) == .stuck)
        #expect(UnresponsiveOwnerWatch.Ensure(Self.stuckEnsure(), pid: nil) == .stuck)
        // An owner at its connection limit answers with a refusal: busy, never stuck.
        #expect(UnresponsiveOwnerWatch.Ensure(busy, pid: nil) == .busy)
        #expect(UnresponsiveOwnerWatch.Ensure(spawn, pid: nil) == .failed)
    }

    @Test func itReplacesOnlyAfterTwoStuckEnsuresOverTheSustainedWindow() async throws {
        let clock = ManualClock()
        let calls = Shared(0)
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: { true },
                                           replace: { claim in calls.current += 1; return claim() })
        watch.note(.ready(pid: 41))
        watch.note(.stuck)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(29))
        watch.note(.stuck)
        #expect(watch.replaceCount == 0, "two stuck ensures inside the window replaced the owner")
        clock.advance(by: .seconds(1))
        await Self.replaces(watch, reach: 1)
        #expect(watch.replaceCount == 1)
        #expect(calls.current == 1)
    }

    @Test func oneStuckEnsureOverTheWindowIsNotEnough() async throws {
        let clock = ManualClock()
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: { true }, replace: Self.claiming)
        watch.note(.stuck)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(31))
        await Self.replaces(watch, reach: 1)
        #expect(watch.replaceCount == 0)
        // The second one, after the window passed, is.
        watch.note(.stuck)
        #expect(watch.replaceCount == 1)
    }

    @Test func aBusyOwnerIsNeverReplaced() async throws {
        let clock = ManualClock()
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: { true }, replace: Self.claiming)
        // Stuck, then busy (it answers again, at its connection limit): the streak ends with its window.
        watch.note(.stuck)
        try await clock.waitForSleeper()
        watch.note(.busy)
        watch.note(.stuck)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(31))
        watch.note(.busy)
        for _ in 0..<10 { watch.note(.busy) }
        clock.advance(by: .seconds(120))
        await Self.replaces(watch, reach: 1)
        #expect(watch.replaceCount == 0, "an owner that answers server.busy was replaced")
    }

    @Test func itReplacesOncePerOwnerProcess() async throws {
        let clock = ManualClock()
        // The replace runs and fails: the same owner stays stuck.
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: { true }, replace: { claim in
            _ = claim()
            return false
        })
        watch.note(.ready(pid: 41))
        watch.note(.stuck)
        watch.note(.stuck)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(30))
        await Self.replaces(watch, reach: 1)
        #expect(watch.replaceCount == 1)
        for _ in 0..<5 { watch.note(.stuck) }
        try? await Task.sleep(for: .milliseconds(50))  // let a wrongly started replace show
        #expect(watch.replaceCount == 1, "the same owner was replaced twice")

        // Another owner process that gets stuck is replaced once too.
        watch.note(.ready(pid: 42))
        watch.note(.stuck)
        watch.note(.stuck)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(30))
        await Self.replaces(watch, reach: 2)
        #expect(watch.replaceCount == 2)
    }

    /// Review of #25382: with the toggle off no streak builds up and no deadline is pending, so
    /// turning it on again needs a fresh window, never one that passed while it was off.
    @Test func theToggleOffStopsTheWindowAndOnAgainNeedsAFreshOne() async throws {
        let clock = ManualClock()
        let enabled = Shared(true)
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: { enabled.current }, replace: Self.claiming)
        watch.note(.stuck)
        try await clock.waitForSleeper()
        #expect(watch.isWaiting)
        enabled.current = false
        watch.note(.stuck)
        #expect(!watch.isWaiting, "a stuck ensure with the toggle off cancels the deadline")
        watch.note(.stuck)
        #expect(!watch.isWaiting)
        clock.advance(by: .seconds(31))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(watch.replaceCount == 0)

        enabled.current = true
        watch.note(.stuck)
        #expect(watch.replaceCount == 0, "on again: the window starts over")
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(30))
        try? await Task.sleep(for: .milliseconds(50))
        watch.note(.stuck)
        #expect(watch.replaceCount == 1)
    }

    /// The toggle turned off while the deadline is pending: it fires, ends the streak and replaces
    /// nothing, also when the toggle is on again at the next stuck ensure.
    @Test func aWindowThatPassesWithTheToggleOffReplacesNothing() async throws {
        let clock = ManualClock()
        let enabled = Shared(true)
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: { enabled.current }, replace: Self.claiming)
        watch.note(.stuck)
        watch.note(.stuck)
        try await clock.waitForSleeper()
        enabled.current = false
        clock.advance(by: .seconds(30))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!watch.isWaiting)
        enabled.current = true
        watch.note(.stuck)
        #expect(watch.replaceCount == 0)
    }

    /// Review of #25382: a stopped watch (the service shut its connection down) cancels its
    /// deadline and replaces nothing after it.
    @Test func aStoppedWatchNeverReplaces() async throws {
        let clock = ManualClock()
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: { true }, replace: Self.claiming)
        watch.note(.stuck)
        watch.note(.stuck)
        try await clock.waitForSleeper()
        watch.stop()
        #expect(!watch.isWaiting)
        clock.advance(by: .seconds(31))
        for _ in 0..<3 { watch.note(.stuck) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(watch.replaceCount == 0)
        #expect(!watch.isWaiting)
    }

    /// Review of #25382: a replace that was queued while the owner was stuck and runs after it
    /// answered again is not run (its claim says no) and is given back, so the same owner is
    /// replaced if it gets stuck again later.
    @Test func aReplaceQueuedBeforeTheOwnerRecoveredDoesNotRun() async throws {
        let clock = ManualClock()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let claims = Shared<[Bool]>([])
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: { true }, replace: { claim in
            for await _ in gate { break }
            let yes = claim()
            claims.current.append(yes)
            return yes
        })
        watch.note(.ready(pid: 41))
        watch.note(.stuck)
        watch.note(.stuck)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(30))
        await Self.replaces(watch, reach: 1)
        #expect(watch.replaceCount == 1, "queued")
        watch.note(.ready(pid: 41))  // the owner answers again before the replace runs
        open.yield()
        for _ in 0..<400 where claims.current.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(claims.current == [false])
        #expect(watch.replaceCount == 0, "given back")

        // Stuck again later: the same owner is replaced this time.
        watch.note(.stuck)
        watch.note(.stuck)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(30))
        await Self.replaces(watch, reach: 1)
        open.yield()
        for _ in 0..<400 where claims.current.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(claims.current == [false, true])
        #expect(watch.replaceCount == 1)
        open.finish()
    }

    /// Bounded wait until the started replaces come down to `count` (a replace given back).
    private static func replaces(_ watch: UnresponsiveOwnerWatch, fallTo count: Int) async {
        for _ in 0..<400 where watch.replaceCount > count {
            try? await Task.sleep(for: .milliseconds(5))  // test harness poll of the replace task
        }
    }

    /// Review 2 of #25382: a replace the recovery refused before it claimed (a Restart of the
    /// person's was running) is given back, so the same owner, still stuck, is replaced later.
    @Test func aReplaceRefusedBeforeItsClaimIsGivenBack() async throws {
        let clock = ManualClock()
        let restarting = Shared(true)
        let claims = Shared(0)
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: { true }, replace: { claim in
            guard !restarting.current else { return false }
            claims.current += 1
            return claim()
        })
        watch.note(.ready(pid: 41))
        watch.note(.stuck)
        watch.note(.stuck)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(30))
        await Self.replaces(watch, reach: 1)
        await Self.replaces(watch, fallTo: 0)
        #expect(watch.replaceCount == 0, "a refused replace was kept and blocks this owner for good")

        // The person's Restart did not help: the owner is still stuck at the next ensure.
        restarting.current = false
        watch.note(.stuck)
        await Self.replaces(watch, reach: 1)
        for _ in 0..<400 where claims.current == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(claims.current == 1)
        #expect(watch.replaceCount == 1)
    }

    /// Review 3 of #25382: the toggle is read, not followed. Turned off and on again between two
    /// reads, the owner stayed stuck the whole time: the streak goes on and the owner is replaced
    /// with the toggle on. Off at a read ends the streak (the tests above and below).
    @Test func theToggleOffAndOnBetweenTwoReadsKeepsTheStreak() async throws {
        let clock = ManualClock()
        let enabled = Shared(true)
        let reads = Shared<[Bool]>([])
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: {
            let on = enabled.current
            reads.current.append(on)
            return on
        }, replace: Self.claiming)
        watch.note(.stuck)
        watch.note(.stuck)
        try await clock.waitForSleeper()
        enabled.current = false  // between two reads: nothing reads it
        enabled.current = true
        clock.advance(by: .seconds(30))
        await Self.replaces(watch, reach: 1)
        #expect(watch.replaceCount == 1)
        #expect(!reads.current.contains(false), "every read the watch made saw the toggle on")
    }

    /// Review 2 of #25382: a queued replace whose claim finds the toggle off ends the streak, so
    /// on again, the next stuck ensure does not replace at once.
    @Test func aClaimThatFindsTheToggleOffEndsTheStreak() async throws {
        let clock = ManualClock()
        let enabled = Shared(true)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let claims = Shared<[Bool]>([])
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: { enabled.current }, replace: { claim in
            for await _ in gate { break }
            let yes = claim()
            claims.current.append(yes)
            return yes
        })
        watch.note(.ready(pid: 41))
        watch.note(.stuck)
        watch.note(.stuck)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(30))
        await Self.replaces(watch, reach: 1)
        enabled.current = false
        open.yield()
        for _ in 0..<400 where claims.current.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(claims.current == [false])
        #expect(watch.replaceCount == 0)

        enabled.current = true
        watch.note(.stuck)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(watch.replaceCount == 0, "the streak from before the toggle went off replaced the owner")
        open.finish()
    }
}
