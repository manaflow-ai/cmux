import CmuxNextCompat

/// The app's daemon-request probe: each request's time from its send to its reply (or its failure),
/// in a fixed log-linear histogram, for the Austin's-day load scenario (scripts/cmux-next/austins-day,
/// #27698: the app request p99 at 80 agents). `debug.daemon_requests` reads it (Debug and bench builds).
///
/// Recording is lock-free and allocation-free: the bucket index is arithmetic on the value, and each
/// bucket, count and maximum is one atomic. Buckets: [0, 64 µs], then four per power of two up to
/// 64 µs << 20 (about 67 s), then one overflow bucket. A reported percentile is its bucket's upper
/// bound, so it is at most 25 % above the true value (the daemon's `server-stats` histograms use the
/// same 4 sub-buckets).
///
/// The local daemon's ``DaemonService`` owns one probe and puts it in its connections' configuration
/// (``DaemonConnectionConfiguration/requestLatency``); each connection's transports record into it.
/// Tests make their own.
public final class DaemonRequestLatency: Sendable {
    /// How a request ended.
    public enum Outcome: Sendable {
        /// An `ok:true` reply.
        case reply
        /// An `ok:false` reply, a closed connection or another failure.
        case error
        /// No reply within the request's deadline (`DaemonError.timedOut`).
        case timedOut
    }

    /// One count per bucket (an atomic is not copyable, so each lives in its own object, made once).
    private final class Counter: Sendable {
        let value = Atomic<UInt64>(0)
    }

    /// Lowest bound (the first bucket holds 0 ... 64 µs) and the powers of two above it.
    static let firstBoundMicroseconds: UInt64 = 64
    static let powers: UInt64 = 20
    static let subBuckets: UInt64 = 4
    /// Every bucket: the bounded ones and the overflow bucket.
    static let bucketCount = 1 + Int(truncatingIfNeeded: powers * subBuckets) + 1

    /// The upper bound of each bucket but the overflow one, in microseconds, rising.
    static let boundsMicroseconds: [UInt64] = {
        var bounds = [firstBoundMicroseconds]
        for power in 0..<powers {
            let base = firstBoundMicroseconds << power
            let step = base / subBuckets
            for sub in 1...subBuckets { bounds.append(base + step * sub) }
        }
        return bounds
    }()

    /// The bucket of a value: the smallest bound at or above it, or the overflow bucket.
    static func bucket(microseconds value: UInt64) -> Int {
        guard value > firstBoundMicroseconds else { return 0 }
        // (64 << k, 64 << (k + 1)] holds `value`; `value - 1` puts each bound in its own bucket.
        let below = value - 1
        let highBit = UInt64(truncatingIfNeeded: UInt64.bitWidth - 1 - below.leadingZeroBitCount)
        let power = highBit - UInt64(truncatingIfNeeded: firstBoundMicroseconds.trailingZeroBitCount)
        guard power < powers else { return bucketCount - 1 }
        let base = firstBoundMicroseconds << power
        let sub = (below - base) / (base / subBuckets)
        return Int(truncatingIfNeeded: 1 + power * subBuckets + sub)
    }

    private let buckets: [Counter]
    private let errors = Atomic<UInt64>(0)
    private let timeouts = Atomic<UInt64>(0)
    private let maxMicroseconds = Atomic<UInt64>(0)

    public init() {
        buckets = (0..<Self.bucketCount).map { _ in Counter() }
    }

    /// Records one request that took `nanoseconds` from its send to its end.
    public func record(nanoseconds: UInt64, outcome: Outcome) { // perf-hot: 1us daemon-request (every app request to the daemon)
        let micros = nanoseconds / 1000
        // `bucket` is below `bucketCount` by construction; `dropFirst` reads it without a trapping subscript.
        buckets.dropFirst(Self.bucket(microseconds: micros)).first?.value.add(1, ordering: .relaxed)
        switch outcome {
        case .reply: break
        case .error: errors.add(1, ordering: .relaxed)
        case .timedOut: timeouts.add(1, ordering: .relaxed)
        }
        var seen = maxMicroseconds.load(ordering: .relaxed)
        while micros > seen {
            let (exchanged, original) = maxMicroseconds.compareExchange(expected: seen, desired: micros, ordering: .relaxed)
            if exchanged { break }
            seen = original
        }
    }

    /// The counts so far (each read is atomic; a request recorded during the read may be in some
    /// counts and not yet in others).
    public func snapshot() -> Snapshot {
        Snapshot(counts: buckets.map { $0.value.load(ordering: .relaxed) },
                 errors: errors.load(ordering: .relaxed),
                 timeouts: timeouts.load(ordering: .relaxed),
                 maxMicroseconds: maxMicroseconds.load(ordering: .relaxed))
    }

    /// A read of the probe.
    public struct Snapshot: Sendable, Equatable {
        /// One count per bucket, the overflow bucket last.
        public let counts: [UInt64]
        public let errors: UInt64
        public let timeouts: UInt64
        public let maxMicroseconds: UInt64

        public var count: UInt64 { counts.reduce(0, +) }
        public var boundsMicroseconds: [UInt64] { DaemonRequestLatency.boundsMicroseconds }

        /// The upper bound of the bucket that holds the `percent`th percentile (nearest rank, `percent`
        /// from 1 to 100); the largest value seen when that is the overflow bucket; nil with no requests.
        public func percentileMicroseconds(_ percent: UInt64) -> UInt64? {
            let total = count
            guard total > 0 else { return nil }
            let rank = max(1, (min(percent, 100) * total + 99) / 100)
            var seen: UInt64 = 0
            for (bucketCount, bound) in zip(counts, boundsMicroseconds.map(Optional.some) + [nil]) {
                seen += bucketCount
                if seen >= rank { return bound ?? maxMicroseconds }
            }
            return maxMicroseconds
        }
    }
}
