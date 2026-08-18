import Testing

@testable import CmuxPeerTransportCore

@Suite struct PeerReconnectBackoffTests {
    @Test func firstDelayIsTheFloor() {
        var backoff = PeerReconnectBackoff(profile: .foregroundClient, seed: 1)
        #expect(backoff.nextDelay() == .seconds(1))
    }

    @Test func delaysNeverExceedTheCap() {
        var backoff = PeerReconnectBackoff(profile: .foregroundClient, seed: 7)
        for _ in 0..<50 {
            let delay = backoff.nextDelay()
            #expect(delay >= .seconds(1))
            #expect(delay <= .seconds(30))
        }
    }

    @Test func sameSeedPinsTheSchedule() {
        var a = PeerReconnectBackoff(profile: .foregroundClient, seed: 42)
        var b = PeerReconnectBackoff(profile: .foregroundClient, seed: 42)
        for _ in 0..<10 {
            #expect(a.nextDelay() == b.nextDelay())
        }
    }

    @Test func resetReturnsToTheFloor() {
        var backoff = PeerReconnectBackoff(profile: .foregroundClient, seed: 3)
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        backoff.reset()
        #expect(backoff.nextDelay() == .seconds(1))
    }

    @Test func serverRetryAfterIsABoundedLowerBound() {
        var backoff = PeerReconnectBackoff(profile: .foregroundClient, seed: 3)
        backoff.noteServerRetryAfter(.seconds(120))
        let delay = backoff.nextDelay()
        // Bounded by the cap even when the server asks for more.
        #expect(delay == .seconds(30))
    }
}
