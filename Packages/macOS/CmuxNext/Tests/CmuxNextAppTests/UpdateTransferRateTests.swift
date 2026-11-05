@testable import CmuxNextUpdater
import Foundation
import Testing

/// Leo 2026-11-05: "can we have, like, a better-looking update downloading thing?". The Downloading Update
/// card shows the time left under the bytes, measured over the last seconds and rounded so
/// the line changes calmly.
struct UpdateTransferRateTests {
    static let expected: UInt64 = 265_300_000
    static let start = Date(timeIntervalSinceReferenceDate: 0)

    static func phase(_ received: UInt64) -> UpdateIndicatorPhase {
        .downloading(.downloading(received: received, expected: expected))
    }

    @Test func nothingShowsUntilASecondOfSamplesIsIn() {
        var rate = UpdateTransferRate()
        rate.record(Self.phase(10_000_000), at: Self.start)
        rate.record(Self.phase(15_000_000), at: Self.start.addingTimeInterval(0.5))
        #expect(rate.text(expected: Self.expected) == nil, "a half-second guess shows")
        rate.record(Self.phase(22_400_000), at: Self.start.addingTimeInterval(1))
        #expect(rate.bytesPerSecond == 12_400_000)
        // 242.9 MB left at 12.4 MB/s: 19.6 s, shown as 20.
        #expect(rate.text(expected: Self.expected)?.contains("20") == true, "\(String(describing: rate.text(expected: Self.expected)))")
    }

    @Test func theTimeLeftRoundsToCalmSteps() {
        var rate = UpdateTransferRate()
        rate.record(Self.phase(0), at: Self.start)
        rate.record(Self.phase(10_000_000), at: Self.start.addingTimeInterval(1))
        // 255.3 MB left at 10 MB/s: 25.53 s, shown as 30.
        #expect(rate.secondsLeft(expected: Self.expected) == 30)
        rate.record(Self.phase(11_000_000), at: Self.start.addingTimeInterval(2))
        // 5.5 MB/s, 254.3 MB left: 46.2 s, shown as 50.
        #expect(rate.secondsLeft(expected: Self.expected) == 50)
        var slow = UpdateTransferRate()
        slow.record(Self.phase(0), at: Self.start)
        slow.record(Self.phase(1_000_000), at: Self.start.addingTimeInterval(1))
        // 264.3 s: whole minutes, rounded up.
        #expect(slow.secondsLeft(expected: Self.expected) == 300)
        #expect(slow.text(expected: Self.expected)?.contains("5 min") == true)
    }

    @Test func theSpeedLooksOnlyAtTheLastFewSeconds() {
        var rate = UpdateTransferRate()
        rate.record(Self.phase(0), at: Self.start)
        rate.record(Self.phase(100_000_000), at: Self.start.addingTimeInterval(1)) // a burst
        for second in 2 ... 12 {
            rate.record(Self.phase(100_000_000 + UInt64(second - 1) * 2_000_000), at: Self.start.addingTimeInterval(Double(second)))
        }
        let speed = rate.bytesPerSecond ?? 0
        #expect(abs(speed - 2_000_000) < 1, "the burst ten seconds ago still swings the speed: \(speed)")
    }

    @Test func anotherPhaseOrANewDownloadStartsOver() {
        var rate = UpdateTransferRate()
        rate.record(Self.phase(0), at: Self.start)
        rate.record(Self.phase(10_000_000), at: Self.start.addingTimeInterval(1))
        rate.record(.downloading(.preparing(0.2)), at: Self.start.addingTimeInterval(2))
        #expect(rate.bytesPerSecond == nil)
        rate.record(Self.phase(50_000_000), at: Self.start.addingTimeInterval(3))
        rate.record(Self.phase(1_000_000), at: Self.start.addingTimeInterval(4))
        #expect(rate.bytesPerSecond == nil, "a count that went back kept the old download's samples")
    }
}
