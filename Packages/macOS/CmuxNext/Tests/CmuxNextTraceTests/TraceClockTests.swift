import CmuxNextTrace
import Darwin
import Foundation
import QuartzCore
import Testing

/// Every trace record is stamped in `CLOCK_UPTIME_RAW` nanoseconds; the converters bring the app's other
/// timestamps onto that clock (plans/cmux-next/trace.md, "Release trace ring v1", "Clock").
struct TraceClockTests {
    private static let second: UInt64 = 1_000_000_000
    private static let microsecond: UInt64 = 1_000

    /// A clock frozen at one uptime and one continuous reading.
    private static func frozen(uptime: UInt64, continuous: ContinuousClock.Instant) -> TraceClock {
        TraceClock(reader: TraceClock.Reader(uptimeNanos: { uptime }, continuousNow: { continuous }))
    }

    @Test func nowNanosReadsClockUptimeRaw() {
        let before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let now = TraceClock().nowNanos()
        let after = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        #expect(before <= now && now <= after)
    }

    /// `ProcessInfo.systemUptime` (the clock `NSEvent.timestamp` uses) and `CACurrentMediaTime()` read the same
    /// clock as `nowNanos()`. Each read lies inside the uptime reads around it (1 us for the seconds' rounding),
    /// and in the tightest of many tries all three agree within 1 us.
    @Test func secondsConvertersAgreeWithNowWithinOneMicrosecond() {
        let clock = TraceClock()
        var tightest = UInt64.max
        for _ in 0 ..< 1_000 {
            let before = clock.nowNanos()
            let uptime = TraceClock.nanos(fromUptimeSeconds: ProcessInfo.processInfo.systemUptime)
            let media = TraceClock.nanos(fromMediaTime: CACurrentMediaTime())
            let after = clock.nowNanos()
            for converted in [uptime, media] {
                #expect(converted + Self.microsecond >= before)
                #expect(converted <= after + Self.microsecond)
            }
            let spread = max(after, uptime, media) - min(before, uptime, media)
            tightest = min(tightest, spread)
        }
        #expect(tightest < Self.microsecond)
    }

    /// The live `ContinuousClock` converts to the uptime reads around it when no sleep falls in between. Each
    /// try takes a fresh stamp, so one preempted stamp costs one try, and each conversion lies inside the reads
    /// around it give or take half its stamp's read width (1 us for rounding). The tightest try is within 1 us.
    @Test func continuousConverterAgreesWithNowWithinOneMicrosecond() {
        let clock = TraceClock()
        var tightest = UInt64.max
        for _ in 0 ..< 1_000 {
            let stamp = clock.continuousStamp()
            let before = clock.nowNanos()
            let converted = TraceClock.nanos(ContinuousClock.now, pairedWith: stamp)
            let after = clock.nowNanos()
            let slack = stamp.readWidthNanos / 2 + Self.microsecond
            #expect(converted + slack >= before)
            #expect(converted <= after + slack)
            let spread = max(after, converted) - min(before, converted)
            tightest = min(tightest, spread + stamp.readWidthNanos / 2)
        }
        #expect(tightest < Self.microsecond)
    }

    /// 1 s awake, a 10 s sleep, 0.25 s awake: `ContinuousClock` moved 11.25 s, uptime 1.25 s. The stamp read at
    /// capture converts exactly; the stamp read before the sleep is off by the whole sleep, so the converter
    /// must never use an offset read at another time.
    @Test func continuousConverterIsExactAcrossAnInjectedTenSecondSleep() {
        let origin = ContinuousClock.now
        let bootUptime: UInt64 = 5 * Self.second
        let beforeSleep = Self.frozen(uptime: bootUptime, continuous: origin).continuousStamp()

        let wokeUptime = bootUptime + Self.second + Self.second / 4
        let wokeContinuous = origin + .seconds(11) + .milliseconds(250)
        let atCapture = Self.frozen(uptime: wokeUptime, continuous: wokeContinuous).continuousStamp()
        #expect(atCapture == TraceClock.ContinuousStamp(continuous: wokeContinuous, uptimeNanos: wokeUptime))

        let later = wokeContinuous + .milliseconds(3)
        let earlier = wokeContinuous - .microseconds(2)
        #expect(TraceClock.nanos(later, pairedWith: atCapture) == wokeUptime + 3_000_000)
        #expect(TraceClock.nanos(earlier, pairedWith: atCapture) == wokeUptime - 2_000)
        #expect(TraceClock.nanos(later, pairedWith: beforeSleep) == wokeUptime + 3_000_000 + 10 * Self.second)
    }

    /// The stamp's uptime is the midpoint of its two reads, and both reads lie between the reads around it.
    @Test func continuousStampPairsAnUptimeReadFromTheSameMoment() {
        let clock = TraceClock()
        let before = clock.nowNanos()
        let stamp = clock.continuousStamp()
        let after = clock.nowNanos()
        let firstRead = stamp.uptimeNanos - stamp.readWidthNanos / 2
        #expect(before <= firstRead)
        #expect(firstRead + stamp.readWidthNanos <= after)
    }

    @Test func secondsConvertersRoundAndClamp() {
        #expect(TraceClock.nanos(fromUptimeSeconds: 1.5) == 3 * Self.second / 2)
        #expect(TraceClock.nanos(fromUptimeSeconds: 1e-9) == 1)
        #expect(TraceClock.nanos(fromUptimeSeconds: 4e-10) == 0)
        #expect(TraceClock.nanos(fromUptimeSeconds: 0) == 0)
        #expect(TraceClock.nanos(fromUptimeSeconds: -1) == 0)
        #expect(TraceClock.nanos(fromUptimeSeconds: .nan) == 0)
        #expect(TraceClock.nanos(fromUptimeSeconds: .infinity) == .max)
        // Three days of uptime keep sub-microsecond precision in a Double.
        let threeDays = TraceClock.nanos(fromUptimeSeconds: 259_200.123_456_789)
        #expect(threeDays >= 259_200_123_456_000 && threeDays <= 259_200_123_457_000)
        #expect(TraceClock.nanos(fromMediaTime: 2.25) == TraceClock.nanos(fromUptimeSeconds: 2.25))
    }

    @Test func aContinuousInstantBeforeUptimeZeroIsZero() {
        let origin = ContinuousClock.now
        let stamp = TraceClock.ContinuousStamp(continuous: origin, uptimeNanos: 1_000)
        #expect(TraceClock.nanos(origin - .seconds(1), pairedWith: stamp) == 0)
    }
}
