import Foundation
@testable import CmuxNextCloud
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Observation
import Testing

/// A Cloud start's wait for its machine (`CloudMachineSession.linkUp`, hq#7060): an ended link is dialed again
/// with a capped backoff until the start's deadline, never past it and never without a delay.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudWaitRedialTests {
    /// A machine's link whose receiver answers only from `upAt` on the test's clock: a dial before then ends the link.
    @MainActor @Observable
    final class LateReceiver {
        let clock: ManualClock
        let upAt: Duration
        var dials = 0
        var connected = false
        init(clock: ManualClock, upAfter delay: Duration) {
            self.clock = clock
            upAt = delay
        }
        func dial() {
            dials += 1
            if clock.now.offset >= upAt { connected = true }
        }
    }

    private static let fast = Backoff(initial: .milliseconds(20), maximum: .milliseconds(80), jitter: 0)

    /// Moves `clock` to the earliest deadline asleep on it, once one is.
    private static func advanceToNextSleeper(_ clock: ManualClock) async throws {
        try await clock.waitForSleeper()
        let next = try #require(clock.sleeperDeadlines.min())
        clock.advance(by: clock.now.duration(to: next))
    }

    @Test func redialsUntilAReceiverThatComesUpLateAnswers() async throws {
        let clock = ManualClock()
        let receiver = LateReceiver(clock: clock, upAfter: .milliseconds(250))
        let wait = Task { await CloudWait.holds(within: .seconds(5), redialing: Self.fast, clock: clock, redial: { receiver.dial() }, until: { receiver.connected }) }
        // Dials at 0, 20, 60, 140 and 220 ms find the receiver down; the one at 300 ms (80 ms capped) answers.
        for _ in 0..<5 { try await Self.advanceToNextSleeper(clock) }
        #expect(await wait.value)
        #expect(receiver.dials == 6)
        #expect(clock.now.offset == .milliseconds(300))
    }

    @Test func endsAtTheDeadlineWithBoundedDialsAndNoneAfter() async throws {
        let clock = ManualClock()
        let receiver = LateReceiver(clock: clock, upAfter: .seconds(3600))
        let wait = Task { await CloudWait.holds(within: .milliseconds(400), redialing: Self.fast, clock: clock, redial: { receiver.dial() }, until: { receiver.connected }) }
        // Dials at 0, 20, 60, 140, 220, 300 and 380 ms; the last wait is cut to the 20 ms left, then none at 400 ms.
        for _ in 0..<7 { try await Self.advanceToNextSleeper(clock) }
        #expect(await wait.value == false)
        #expect(receiver.dials == 7)
        #expect(clock.now.offset == .milliseconds(400))
        #expect(clock.sleeperCount == 0, "nothing is left to dial after the deadline")
    }

    @Test func aCancelledWaitStopsDialing() async throws {
        let clock = ManualClock()
        let receiver = LateReceiver(clock: clock, upAfter: .seconds(3600))
        let wait = Task { await CloudWait.holds(within: .seconds(30), redialing: Self.fast, clock: clock, redial: { receiver.dial() }, until: { receiver.connected }) }
        try await clock.waitForSleeper()
        wait.cancel()
        #expect(await wait.value == false)
        #expect(receiver.dials == 1, "a cancelled wait dialed again")
    }

    @Test func onlyADownOrRevokedLinkIsADrop() {
        #expect(CloudLinkError.isDrop(CloudLinkError.disconnected(reason: "")))
        #expect(CloudLinkError.isDrop(CloudLinkError.revoked(reason: "x")))
        #expect(!CloudLinkError.isDrop(CloudLinkError.failed(code: "c", message: "")))
        #expect(!CloudLinkError.isDrop(CloudLinkError.unsafeSocket("x")))
        #expect(!CloudLinkError.isDrop(CloudAppOpError(code: "c", message: "m")))
    }
}
