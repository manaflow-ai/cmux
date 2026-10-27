import CmuxNextWakeups
import QuartzCore
import Testing

/// The display-link seam (p15-oracle task 125): the schedulers decide rates as ``FrameRateRange`` and read
/// ``DisplayClock/systemMediaTime()``; Core Animation gets the same values and the same clock it had before.
@MainActor
struct DisplayLinkSeamTests {
    @Test func everyRateReachesCoreAnimationAsTheRangeItAskedForBefore() {
        let expected: [(FrameRate, CAFrameRateRange)] = [
            (.motion, CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)),
            (.ui, CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)),
            (.ambient, CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)),
            (.slow(8), CAFrameRateRange(minimum: 8, maximum: 30, preferred: 8)),
        ]
        for (rate, range) in expected {
            #expect(Self.same(rate.range, range), "\(rate) asks for \(rate.range), not \(range)")
        }
        let open = FrameRateRange(minimum: 10, maximum: 60, preferred: nil)
        #expect(CAFrameRateRange(open).preferred == nil, "no preferred rate leaves the system to pick")
    }

    @Test func systemMediaTimeIsTheDisplayLinksClock() {
        let before = CACurrentMediaTime()
        let now = DisplayClock.systemMediaTime()
        let after = CACurrentMediaTime()
        // Both read mach_absolute_time; the bounds allow one microsecond of conversion rounding.
        #expect(now >= before - 1e-6 && now <= after + 1e-6, "\(before) <= \(now) <= \(after)")
    }

    /// `CAFrameRateRange` is not `Equatable`: the fields the link reads.
    private static func same(_ lhs: CAFrameRateRange, _ rhs: CAFrameRateRange) -> Bool {
        lhs.minimum == rhs.minimum && lhs.maximum == rhs.maximum && lhs.preferred == rhs.preferred
    }
}
