internal import CCmuxDaemonConnFFI

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
///
/// The histogram is Rust's (`cmux_daemon_latency_*`, cmux-daemon-conn-core src/latency.rs).
// crash-allow: the Rust probe is atomics only (record and snapshot are lock-free from any thread); the immutable handle is freed once, in deinit
public final class DaemonRequestLatency: @unchecked Sendable {
    /// How a request ended.
    public enum Outcome: Sendable {
        /// An `ok:true` reply.
        case reply
        /// An `ok:false` reply, a closed connection or another failure.
        case error
        /// No reply within the request's deadline (`DaemonError.timedOut`).
        case timedOut
    }

    /// Every bucket: the bounded ones and the overflow bucket.
    static let bucketCount = cmux_daemon_latency_bucket_count()

    /// The upper bound of each bucket but the overflow one, in microseconds, rising (`latency_bounds`).
    static let boundsMicroseconds: [UInt64] = {
        let bounds = DaemonConnRules.call("latency_bounds")?["bounds_us"] as? [NSNumber]
        return bounds?.map(\.uint64Value) ?? []
    }()

    private let probe: OpaquePointer?

    public init() {
        probe = cmux_daemon_latency_new()
    }

    deinit {
        cmux_daemon_latency_free(probe)
    }

    /// Records one request that took `nanoseconds` from its send to its end.
    public func record(nanoseconds: UInt64, outcome: Outcome) { // perf-hot: 1us daemon-request (every app request to the daemon)
        let code: UInt32 = switch outcome {
        case .reply: 0
        case .error: 1
        case .timedOut: 2
        }
        cmux_daemon_latency_record(probe, nanoseconds, code)
    }

    /// The counts so far (each read is atomic; a request recorded during the read may be in some
    /// counts and not yet in others).
    public func snapshot() -> Snapshot {
        var totals = CmuxDaemonLatencyTotals(errors: 0, timeouts: 0, max_us: 0)
        var counts = [UInt64](repeating: 0, count: Self.bucketCount)
        let written = counts.withUnsafeMutableBufferPointer { buffer in
            cmux_daemon_latency_snapshot(probe, buffer.baseAddress, buffer.count, &totals)
        }
        return Snapshot(counts: Array(counts.prefix(written)), errors: totals.errors, timeouts: totals.timeouts,
                        maxMicroseconds: totals.max_us)
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
        /// from 1 to 100); the largest value seen when that is the overflow bucket; nil with no requests
        /// (`latency_percentile`).
        public func percentileMicroseconds(_ percent: UInt64) -> UInt64? {
            let reply = DaemonConnRules.call("latency_percentile",
                                             ["counts": counts, "max_us": maxMicroseconds, "percent": percent])
            return (reply?["us"] as? NSNumber)?.uint64Value
        }
    }
}
