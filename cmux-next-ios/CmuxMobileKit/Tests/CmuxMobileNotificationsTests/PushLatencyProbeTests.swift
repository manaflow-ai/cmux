import Foundation
import Testing
@testable import CmuxMobileNotifications

@Suite("PushLatencyProbe")
struct PushLatencyProbeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000.250)

    @Test("the latency is receive minus the sender's stamp")
    func difference() {
        #expect(PushLatencyProbe.latencyMs(userInfo: ["cmuxSentAtMs": 1_800_000_000_000 as Int64], now: now) == 250)
    }

    @Test("a push without a stamp, or with a nonsense one, logs nothing")
    func unstamped() {
        #expect(PushLatencyProbe.record(userInfo: ["cmux": ["eventId": "e"]], now: now) == nil)
        #expect(PushLatencyProbe.record(userInfo: [:], now: now) == nil)
        #expect(PushLatencyProbe.record(userInfo: ["cmuxSentAtMs": 5], now: now) == nil)
        #expect(PushLatencyProbe.record(userInfo: ["cmuxSentAtMs": "x"], now: now) == nil)
    }
}
