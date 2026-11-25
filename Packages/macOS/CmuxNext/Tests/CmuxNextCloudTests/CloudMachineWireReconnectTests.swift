import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
@testable import CmuxNextCloud
import Testing

/// The Cloud event socket's reconnect loop: a network change ends a backoff wait at once (Wi-Fi back no longer waits
/// out up to 30 s), a change during a dial is kept for the next wait, and with no change the backoff spaces dials.
@MainActor
struct CloudMachineWireReconnectTests {
    private final class Dials {
        var count = 0
        var at: [ContinuousClock.Instant] = []
    }

    /// A backoff whose first step is far longer than the test: only a wake can end the wait.
    private static let longBackoff = Backoff(initial: .seconds(60), maximum: .seconds(60), jitter: 0, random: { 0.5 })

    @Test func networkChangeEndsTheBackoffWaitAtOnce() async {
        let wake = RetryWake(owner: "test.cloud.wire")
        let dials = Dials()
        let loop = Task { @MainActor in
            await CloudMachineWire.reconnecting(wake: wake, backoff: Self.longBackoff, keepGoing: { dials.count < 2 }) { _ in
                dials.count += 1
                dials.at.append(.now)
                throw URLError(.notConnectedToInternet)
            }
        }
        // The first dial failed and the loop waits its 60 s step.
        while dials.count < 1 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(dials.count == 1)
        wake.fire()
        await loop.value
        #expect(dials.count == 2)
        #expect(dials.at[1] - dials.at[0] < .seconds(5))
    }

    @Test func aChangeDuringTheDialEndsTheNextWait() async {
        let wake = RetryWake(owner: "test.cloud.wire")
        let dials = Dials()
        let started = ContinuousClock.now
        await CloudMachineWire.reconnecting(wake: wake, backoff: Self.longBackoff, keepGoing: { dials.count < 2 }) { _ in
            dials.count += 1
            // The network changed while the dial ran on the old one.
            if dials.count == 1 { wake.fire() }
            throw URLError(.networkConnectionLost)
        }
        #expect(dials.count == 2)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func subscribingStartsTheBackoffOver() async {
        let wake = RetryWake(owner: "test.cloud.wire")
        let dials = Dials()
        let short = Backoff(initial: .milliseconds(100), maximum: .seconds(60), jitter: 0, random: { 0.5 })
        let started = ContinuousClock.now
        // Five waits of 100 ms; without the reset they would double to 1.6 s, 3.1 s in all.
        await CloudMachineWire.reconnecting(wake: wake, backoff: short, keepGoing: { dials.count < 6 }) { onSubscribed in
            dials.count += 1
            onSubscribed()
            throw URLError(.networkConnectionLost)
        }
        #expect(dials.count == 6)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func cancellationEndsTheLoop() async {
        let wake = RetryWake(owner: "test.cloud.wire")
        let dials = Dials()
        let loop = Task { @MainActor in
            await CloudMachineWire.reconnecting(wake: wake, backoff: Self.longBackoff, keepGoing: { true }) { _ in
                dials.count += 1
                throw URLError(.notConnectedToInternet)
            }
        }
        while dials.count < 1 { await Task.yield() }
        loop.cancel()
        await loop.value
        #expect(dials.count == 1)
    }
}
