import CmuxNextCompat

/// The app's send-to-reply time per daemon method: one log-linear histogram per method, in
/// microseconds, with the daemon's bucket edges (cmux-tui `diagnostics::LogLinearHistogram`: four
/// linear sub-buckets per power of two). A percentile is the upper bound of its bucket, as the
/// daemon's `server-stats` `ipc` reports it, so the two ends of one request and a bench's raw samples
/// agree within one bucket. Chromium counts IPC timing per message type the same way, lock-free into
/// fixed bucket arrays (base/metrics/histogram_macros.h, `UMA_HISTOGRAM_CUSTOM_MICROSECONDS_TIMES`;
/// mojo/core/channel.cc).
///
/// A request that never gets its reply is counted too, so the slowest requests are not missing from
/// the distribution: one that timed out counts in the histogram at its deadline (its time was at
/// least that) and in `timedOut`; one whose connection closed first counts in `abandoned` only.
///
/// Every histogram lives in one fixed allocation made at init: recording is a dictionary lookup of
/// the method name, three relaxed atomic adds and, for a new maximum, a compare-exchange. It takes no
/// lock and allocates nothing.
final class DaemonMethodLatency: Sendable {
    /// Buckets per power of two (as the daemon).
    static let subBucketsLog2: UInt64 = 2
    static let subBuckets = 1 << subBucketsLog2
    /// Powers of two kept: samples of 2^30 µs (about 18 minutes) or more count in the last bucket.
    static let octaves = 30
    static let bucketCount = octaves * subBuckets
    /// Per method: its buckets, its largest sample, its timed-out and its abandoned requests.
    private static let maxWord = bucketCount
    private static let timedOutWord = bucketCount + 1
    private static let abandonedWord = bucketCount + 2
    private static let methodWords = bucketCount + 3

    /// The methods by slot; the last slot counts every `cmd` the table does not name.
    let methods: [DaemonWireStats.Method]
    private let slots: [String: Int]
    /// `methods.count * methodWords` zeroed words; allocated once, never resized.
    nonisolated(unsafe) private let words: UnsafeMutablePointer<UInt64> // crash-allow: one fixed allocation; every access after init is an atomic operation (AtomicPointerSlot)
    private var wordCount: Int { methods.count * Self.methodWords }

    /// The slot of a request whose `cmd` no method has.
    var otherSlot: Int { methods.count - 1 }

    init(methods table: [DaemonWireStats.Method]) {
        methods = table + [DaemonWireStats.Method(id: nil, name: DaemonWireStats.Method.otherName)]
        var slots: [String: Int] = [:]
        for (slot, method) in table.enumerated() where slots[method.name] == nil { slots[method.name] = slot }
        self.slots = slots
        let count = methods.count * Self.methodWords
        // SAFETY: a fresh allocation of `count` words, every one initialized to zero here; it is freed once, in
        // deinit, and never resized.
        words = unsafe UnsafeMutablePointer<UInt64>.allocate(capacity: count)
        unsafe words.initialize(repeating: 0, count: count)
    }

    deinit {
        // SAFETY: the allocation of init, `wordCount` initialized words; nothing else holds `self` any more.
        unsafe words.deinitialize(count: wordCount)
        unsafe words.deallocate()
    }

    /// The slot that counts requests named `cmd`.
    func slot(of cmd: String) -> Int { slots[cmd] ?? otherSlot }

    /// The bucket a sample of `micros` counts in (the daemon's `bucket_index`, clamped to the last bucket).
    static func bucket(forMicros micros: UInt64) -> Int {
        // Every conversion below is of a value under 64.
        guard micros >= 1 << subBucketsLog2 else { return Int(truncatingIfNeeded: micros) }
        let octave = 63 - micros.leadingZeroBitCount
        let sub = Int(truncatingIfNeeded: (micros >> (octave - Int(truncatingIfNeeded: subBucketsLog2))) & (1 << subBucketsLog2 - 1))
        return min(octave * subBuckets + sub, bucketCount - 1)
    }

    /// The largest sample bucket `index` holds (the daemon's `bucket_upper_bound`). Buckets 4..<8 hold
    /// nothing (2 and 3 have buckets of their own) and answer 3.
    static func upperBound(ofBucket index: Int) -> UInt64 {
        guard index >= 2 * subBuckets else { return UInt64(truncatingIfNeeded: min(max(index, 0), subBuckets - 1)) }
        let octave = UInt64(truncatingIfNeeded: index / subBuckets)
        let sub = UInt64(truncatingIfNeeded: index % subBuckets)
        let width: UInt64 = 1 << (octave - subBucketsLog2)
        return ((1 << octave) - 1) + (sub + 1) * width
    }

    @inline(__always)
    private func word(_ slot: Int, _ index: Int) -> AtomicPointerSlot {
        word(at: slot * Self.methodWords + index)
    }

    /// The word at `offset`; every caller passes an offset under ``wordCount``.
    @inline(__always)
    private func word(at offset: Int) -> AtomicPointerSlot {
        assert(offset >= 0 && offset < wordCount)
        // SAFETY: offset is under wordCount (callers: a slot under methods.count, checked by record and read
        // by snapshot's own loop, times methodWords plus a word index under methodWords; reset's range), so the
        // word is inside the allocation, which lives as long as `self`; allocate aligns it for UInt64.
        return unsafe AtomicPointerSlot(words + offset)
    }

    /// Counts one reply that came `micros` after its request was sent.
    // perf-hot: 1us daemon-request
    func record(slot: Int, micros: UInt64) {
        guard slot >= 0, slot < methods.count else { return }
        word(slot, Self.bucket(forMicros: micros)).add(1, ordering: .relaxed)
        let maximum = word(slot, Self.maxWord)
        var seen = maximum.load(ordering: .relaxed)
        while micros > seen {
            let (exchanged, original) = maximum.compareExchange(expected: seen, desired: micros, ordering: .relaxed)
            if exchanged { break }
            seen = original
        }
    }

    /// Counts one request that got no reply within its deadline, `micros` after it was sent: a
    /// sample at the deadline and one `timedOut`. Its late reply, if any, is not timed.
    func recordTimeout(slot: Int, micros: UInt64) {
        guard slot >= 0, slot < methods.count else { return }
        record(slot: slot, micros: micros)
        word(slot, Self.timedOutWord).add(1, ordering: .relaxed)
    }

    /// Counts one request whose connection closed before its reply.
    func recordAbandoned(slot: Int) {
        guard slot >= 0, slot < methods.count else { return }
        word(slot, Self.abandonedWord).add(1, ordering: .relaxed)
    }

    /// Every method with a sample or an unanswered request, in table order (allocates; read off the
    /// hot path).
    func snapshot() -> [DaemonWireStats.MethodLatency] {
        zip(methods.indices, methods).compactMap { slot, method in
            let counts = (0..<Self.bucketCount).map { word(slot, $0).load(ordering: .relaxed) }
            let count = counts.reduce(0, &+)
            let timedOut = word(slot, Self.timedOutWord).load(ordering: .relaxed)
            let abandoned = word(slot, Self.abandonedWord).load(ordering: .relaxed)
            guard count > 0 || abandoned > 0 else { return nil }
            func percentile(_ fraction: Double) -> UInt64 {
                guard count > 0 else { return 0 }
                let rank = max(1, UInt64(exactly: (Double(count) * fraction).rounded(.up)) ?? count)
                var seen: UInt64 = 0
                for (index, inBucket) in counts.enumerated() {
                    seen &+= inBucket
                    if seen >= rank { return Self.upperBound(ofBucket: index) }
                }
                return Self.upperBound(ofBucket: Self.bucketCount - 1)
            }
            return DaemonWireStats.MethodLatency(
                method: method.name, id: method.id, count: count,
                p50Micros: percentile(0.50), p95Micros: percentile(0.95), p99Micros: percentile(0.99),
                maxMicros: word(slot, Self.maxWord).load(ordering: .relaxed),
                timedOut: timedOut, abandoned: abandoned)
        }
    }

    /// Zeroes every histogram. A sample recorded during the reset may be lost.
    func reset() {
        for index in 0..<wordCount { word(at: index).store(0, ordering: .relaxed) }
    }
}
