import Foundation
@testable import CmuxNextCloud
import CmuxNextWakeups
import Testing

/// A Cloud start's wait for its machine (`CloudMachineSession.linkUp`, hq#7060): an ended link is dialed again
/// with a capped backoff until the start's deadline, never past it and never without a delay.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudWaitRedialTests {
    /// A machine's link whose receiver answers only from `upAt` on: a dial before then ends the link.
    @MainActor
    private final class LateReceiver {
        let upAt: ContinuousClock.Instant
        var dials = 0
        var connected = false
        init(upAfter delay: Duration) { upAt = ContinuousClock.now.advanced(by: delay) }
        func dial() {
            dials += 1
            if ContinuousClock.now >= upAt { connected = true }
        }
    }

    private static let fast = Backoff(initial: .milliseconds(20), maximum: .milliseconds(80), jitter: 0)

    @Test func redialsUntilAReceiverThatComesUpLateAnswers() async {
        let receiver = LateReceiver(upAfter: .milliseconds(250))
        let started = ContinuousClock.now
        let up = await CloudWait.holds(within: .seconds(5), redialing: Self.fast, redial: { receiver.dial() }, until: { receiver.connected })
        #expect(up)
        #expect(started.duration(to: .now) < .seconds(2), "the wait did not end soon after the receiver came up")
        // 20 + 40 + 80 + 80 + ... ms: about six dials reach 250 ms; a spin would make hundreds.
        #expect((2...12).contains(receiver.dials), "dials: \(receiver.dials)")
    }

    @Test func endsAtTheDeadlineWithBoundedDialsAndNoneAfter() async {
        let receiver = LateReceiver(upAfter: .seconds(3600))
        let started = ContinuousClock.now
        let up = await CloudWait.holds(within: .milliseconds(400), redialing: Self.fast, redial: { receiver.dial() }, until: { receiver.connected })
        let elapsed = started.duration(to: .now)
        #expect(!up)
        #expect(elapsed >= .milliseconds(400) && elapsed < .seconds(2), "elapsed: \(elapsed)")
        #expect((3...10).contains(receiver.dials), "dials: \(receiver.dials)")
        let dials = receiver.dials
        try? await Task.sleep(for: .milliseconds(200))
        #expect(receiver.dials == dials, "a dial after the deadline")
    }

    @Test func aCancelledWaitStopsDialing() async {
        let receiver = LateReceiver(upAfter: .seconds(3600))
        let wait = Task { await CloudWait.holds(within: .seconds(30), redialing: Self.fast, redial: { receiver.dial() }, until: { receiver.connected }) }
        try? await Task.sleep(for: .milliseconds(100))
        wait.cancel()
        #expect(await wait.value == false)
        let dials = receiver.dials
        try? await Task.sleep(for: .milliseconds(200))
        #expect(receiver.dials == dials)
    }

    @Test func onlyADownOrRevokedLinkIsADrop() {
        #expect(CloudLinkError.isDrop(CloudLinkError.disconnected(reason: "")))
        #expect(CloudLinkError.isDrop(CloudLinkError.revoked(reason: "x")))
        #expect(!CloudLinkError.isDrop(CloudLinkError.failed(code: "c", message: "")))
        #expect(!CloudLinkError.isDrop(CloudLinkError.unsafeSocket("x")))
        #expect(!CloudLinkError.isDrop(CloudAppOpError(code: "c", message: "m")))
    }
}
