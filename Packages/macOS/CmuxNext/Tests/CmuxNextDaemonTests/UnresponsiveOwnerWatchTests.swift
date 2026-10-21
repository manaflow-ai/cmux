import CmuxNextCompat
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
                                           replace: { calls.current += 1; return true })
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
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: { true }, replace: { true })
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
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: { true }, replace: { true })
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
        // The replace is refused: the same owner stays stuck.
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: { true }, replace: { false })
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

    @Test func theToggleOffKeepsTheOwnerUntilItIsOnAgain() async throws {
        let clock = ManualClock()
        let enabled = Shared(false)
        let watch = UnresponsiveOwnerWatch(policy: .standard, clock: clock, isEnabled: { enabled.current }, replace: { true })
        watch.note(.stuck)
        watch.note(.stuck)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(31))
        try? await Task.sleep(for: .milliseconds(200))  // the window's deadline runs off this task
        #expect(watch.replaceCount == 0)
        enabled.current = true
        watch.note(.stuck)
        #expect(watch.replaceCount == 1)
    }
}
