import Testing
@testable import CmuxNextDaemon

/// The app's daemon-request probe (`debug.daemon_requests`): each request's send-to-reply time goes
/// into a fixed log-linear bucket (4 per power of two from 64 µs), so the Austin's-day harness can read
/// the app request p99 under load. These pin the bucket math: a value lands in the bucket whose upper
/// bound is the smallest one at or above it, past the last bound it lands in the overflow bucket, and
/// a reported percentile is that bucket's upper bound (at most 25 % above the true value).
struct DaemonRequestLatencyTests {
    @Test func boundsAreFourPerPowerOfTwoFrom64Microseconds() {
        let bounds = DaemonRequestLatency.boundsMicroseconds
        #expect(Array(bounds.prefix(9)) == [64, 80, 96, 112, 128, 160, 192, 224, 256])
        #expect(bounds.count == DaemonRequestLatency.bucketCount - 1)
        // Strictly rising, and the last bound is past a minute (the longest request deadline).
        #expect(zip(bounds, bounds.dropFirst()).allSatisfy { $0 < $1 })
        #expect(bounds.last! > 60_000_000)
    }

    /// The bucket a single request of `micros` lands in, read back through the Rust probe.
    private static func bucket(microseconds micros: UInt64) -> Int? {
        let probe = DaemonRequestLatency()
        probe.record(nanoseconds: micros.multipliedReportingOverflow(by: 1000).overflow ? .max : micros * 1000,
                     outcome: .reply)
        return probe.snapshot().counts.firstIndex(of: 1)
    }

    @Test func aValueLandsInTheSmallestBucketWhoseBoundHoldsIt() {
        let bounds = DaemonRequestLatency.boundsMicroseconds
        #expect(Self.bucket(microseconds: 0) == 0)
        #expect(Self.bucket(microseconds: 64) == 0)
        #expect(Self.bucket(microseconds: 65) == 1)
        #expect(Self.bucket(microseconds: 80) == 1)
        #expect(Self.bucket(microseconds: 129) == 5)
        // Every bound and its neighbours, against a linear search.
        for (index, bound) in bounds.enumerated() {
            #expect(Self.bucket(microseconds: bound) == index)
            #expect(Self.bucket(microseconds: bound + 1) == index + 1)
            // Bounds are at least 16 µs apart, so one below a bound is still in its bucket.
            if index > 0 { #expect(Self.bucket(microseconds: bound - 1) == index) }
        }
        #expect(Self.bucket(microseconds: .max) == DaemonRequestLatency.bucketCount - 1)
    }

    @Test func recordsCountsOutcomesAndMaxAndReadsPercentiles() {
        let probe = DaemonRequestLatency()
        for _ in 0..<98 { probe.record(nanoseconds: 1_000_000, outcome: .reply) } // 1 ms
        probe.record(nanoseconds: 40_000_000, outcome: .error) // 40 ms
        probe.record(nanoseconds: 2_000_000_000, outcome: .timedOut) // 2 s
        let snapshot = probe.snapshot()
        #expect(snapshot.count == 100)
        #expect(snapshot.errors == 1)
        #expect(snapshot.timeouts == 1)
        #expect(snapshot.maxMicroseconds == 2_000_000)
        #expect(snapshot.counts.reduce(0, +) == 100)
        #expect(snapshot.counts.max() == 98)
        // Upper bounds: 1 ms is in (896, 1024], 40 ms in (40960 - 8192, 40960], 2 s in (1835008, 2097152].
        #expect(snapshot.percentileMicroseconds(50) == 1024)
        #expect(snapshot.percentileMicroseconds(99) == 40960)
        #expect(snapshot.percentileMicroseconds(100) == 2_097_152)
        #expect(DaemonRequestLatency().snapshot().percentileMicroseconds(99) == nil)
    }
}
