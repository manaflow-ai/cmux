import Testing

@testable import CMUXMobileCore

@Suite struct ConnectionOutageThrottleTests {
    @Test func firstDropEmitsLost() {
        var throttle = ConnectionOutageThrottle()
        let signal = throttle.record(transition: .init(wasConnected: true, isConnected: false))
        #expect(signal == .lost)
        #expect(throttle.outageOpen)
    }

    @Test func flappingDuringOutageEmitsOnce() {
        var throttle = ConnectionOutageThrottle()
        #expect(throttle.record(transition: .init(wasConnected: true, isConnected: false)) == .lost)
        // A repeated disconnected→disconnected churn must not re-emit.
        #expect(throttle.record(transition: .init(wasConnected: false, isConnected: false)) == nil)
        // Another connected→disconnected edge while the outage is still open: no
        // second lost.
        #expect(throttle.record(transition: .init(wasConnected: true, isConnected: false)) == nil)
        #expect(throttle.outageOpen)
    }

    @Test func recoveryAfterOutageEmitsRecovered() {
        var throttle = ConnectionOutageThrottle()
        _ = throttle.record(transition: .init(wasConnected: true, isConnected: false))
        let signal = throttle.record(transition: .init(wasConnected: false, isConnected: true))
        #expect(signal == .recovered)
        #expect(!throttle.outageOpen)
    }

    @Test func recoveryWithoutOpenOutageIsNoop() {
        var throttle = ConnectionOutageThrottle()
        let signal = throttle.record(transition: .init(wasConnected: false, isConnected: true))
        #expect(signal == nil)
        #expect(!throttle.outageOpen)
    }

    @Test func fullOutageCycleEmitsExactlyOneLostOneRecovered() {
        var throttle = ConnectionOutageThrottle()
        var signals: [ConnectionOutageThrottle.Signal] = []
        let transitions: [ConnectionOutageThrottle.Transition] = [
            .init(wasConnected: true, isConnected: false),  // lost
            .init(wasConnected: false, isConnected: false), // flap
            .init(wasConnected: false, isConnected: true),  // recovered
            .init(wasConnected: true, isConnected: true),   // steady
            .init(wasConnected: true, isConnected: false),  // lost again (new outage)
            .init(wasConnected: false, isConnected: true),  // recovered again
        ]
        for transition in transitions {
            if let signal = throttle.record(transition: transition) { signals.append(signal) }
        }
        #expect(signals == [.lost, .recovered, .lost, .recovered])
    }
}
