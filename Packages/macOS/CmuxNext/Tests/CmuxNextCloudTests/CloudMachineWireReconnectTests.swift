import CmuxNextDaemon
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
@testable import CmuxNextCloud
import Testing

/// The Cloud event socket's reconnect loop: a network change ends a backoff wait at once (Wi-Fi back no longer waits
/// out up to 30 s), a change during a dial is kept for the next wait, and with no change the backoff spaces dials.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct CloudMachineWireReconnectTests {
    private final class Dials {
        var count = 0
    }

    /// A backoff whose first step is far longer than the test: only a wake can end the wait.
    private static let longBackoff = Backoff(initial: .seconds(60), maximum: .seconds(60), jitter: 0, random: { 0.5 })

    @Test func networkChangeEndsTheBackoffWaitAtOnce() async throws {
        let clock = ManualClock()
        let wake = RetryWake(owner: "test.cloud.wire")
        let dials = Dials()
        let loop = Task { @MainActor in
            await CloudMachineWire.reconnecting(wake: wake, backoff: Self.longBackoff, clock: clock, keepGoing: { dials.count < 2 }) { _ in
                dials.count += 1
                throw URLError(.notConnectedToInternet)
            }
        }
        // The first dial failed and the loop waits its 60 s step.
        defer { loop.cancel() }
        try await clock.waitForSleeper()
        #expect(dials.count == 1)
        wake.fire()
        await loop.value
        #expect(dials.count == 2)
        #expect(clock.now.offset == .zero)
    }

    @Test func aChangeDuringTheDialEndsTheNextWait() async {
        let clock = ManualClock()
        let wake = RetryWake(owner: "test.cloud.wire")
        let dials = Dials()
        await CloudMachineWire.reconnecting(wake: wake, backoff: Self.longBackoff, clock: clock, keepGoing: { dials.count < 2 }) { _ in
            dials.count += 1
            // The network changed while the dial ran on the old one.
            if dials.count == 1 { wake.fire() }
            throw URLError(.networkConnectionLost)
        }
        #expect(dials.count == 2)
        #expect(clock.now.offset == .zero)
    }

    @Test func subscribingStartsTheBackoffOver() async throws {
        let clock = ManualClock()
        let wake = RetryWake(owner: "test.cloud.wire")
        let dials = Dials()
        let short = Backoff(initial: .milliseconds(100), maximum: .seconds(60), jitter: 0, random: { 0.5 })
        let loop = Task { @MainActor in
            await CloudMachineWire.reconnecting(wake: wake, backoff: short, clock: clock, keepGoing: { dials.count < 6 }) { onSubscribed in
                dials.count += 1
                onSubscribed()
                throw URLError(.networkConnectionLost)
            }
        }
        defer { loop.cancel() }
        for count in 1...5 {
            try await clock.waitForSleeper()
            #expect(dials.count == count)
            let deadline = try #require(clock.sleeperDeadlines.min())
            #expect(clock.now.duration(to: deadline) == .milliseconds(100))
            clock.advance(by: .milliseconds(100))
        }
        await loop.value
        #expect(dials.count == 6)
        #expect(clock.now.offset == .milliseconds(500))
    }

    @Test func cancellationEndsTheLoop() async throws {
        let clock = ManualClock()
        let wake = RetryWake(owner: "test.cloud.wire")
        let dials = Dials()
        let loop = Task { @MainActor in
            await CloudMachineWire.reconnecting(wake: wake, backoff: Self.longBackoff, clock: clock, keepGoing: { true }) { _ in
                dials.count += 1
                throw URLError(.notConnectedToInternet)
            }
        }
        defer { loop.cancel() }
        try await clock.waitForSleeper()
        loop.cancel()
        await loop.value
        #expect(dials.count == 1)
    }
}
