import CmuxNextCompat
import CmuxNextWakeups
import Testing

/// The wakeup ledger's counts and rates (debug.wakeups), kept while ``WakeupLedger/record(_:reason:count:)``
/// changes its counters in place.
@Suite struct WakeupLedgerTests {
    @Test func countsAndRatesArePerOwnerAndReason() throws {
        let uptime = Uptime(seconds: 100)
        let ledger = WakeupLedger(uptime: uptime.read)
        for second in 0..<10 {
            for _ in 0..<12 { ledger.record("spring", reason: "frame") }
            ledger.record("spring", reason: "deadline", count: 3)
            uptime.set(seconds: 101 + UInt64(second))
        }
        ledger.record("store", reason: "frame")
        let entries = ledger.snapshot()
        let frames = try #require(entries.first { $0.owner == "spring" && $0.reason == "frame" })
        #expect(frames.count == 120)
        #expect(frames.perSecond == 12)
        let deadlines = try #require(entries.first { $0.owner == "spring" && $0.reason == "deadline" })
        #expect(deadlines.count == 30)
        #expect(deadlines.perSecond == 3)
        let store = try #require(entries.first { $0.owner == "store" })
        #expect(store.count == 1)
        #expect(store.perSecond == 0, "the current second is not complete yet")
        #expect(entries.first?.owner == "spring" && entries.first?.reason == "frame", "busiest first")
    }

    @Test func oldSecondsDropOutOfTheRate() throws {
        let uptime = Uptime(seconds: 50)
        let ledger = WakeupLedger(uptime: uptime.read)
        for _ in 0..<40 { ledger.record("spring", reason: "frame") }
        uptime.set(seconds: 51)
        #expect(try #require(ledger.snapshot().first).perSecond == 4)
        uptime.set(seconds: 80)
        ledger.record("spring", reason: "frame")
        let entry = try #require(ledger.snapshot().first)
        #expect(entry.count == 41)
        #expect(entry.perSecond == 0)
    }
}

private final class Uptime: Sendable {
    private let nanos: Mutex<UInt64>
    init(seconds: UInt64) { nanos = Mutex(seconds * 1_000_000_000) }
    nonisolated deinit {}
    var read: @Sendable () -> UInt64 { { [self] in nanos.withLock { $0 } } }
    func set(seconds: UInt64) { nanos.withLock { $0 = seconds * 1_000_000_000 } }
}
