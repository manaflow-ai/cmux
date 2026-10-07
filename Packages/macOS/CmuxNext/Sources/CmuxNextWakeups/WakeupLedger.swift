import Foundation
import Synchronization

/// Counts every wakeup the sanctioned primitives perform, per owner and
/// reason (plans/cmux-next/idle-wakeups.md). An idle app records nothing:
/// the ledger has no timer of its own, and rates are computed lazily from
/// one-second buckets when someone records or reads.
///
/// `debug.wakeups` reads ``snapshot(now:)``; the busy watchdog reads
/// ``activitySequence`` to know whether anything woke since its last look.
public final class WakeupLedger: Sendable {
    public static let shared = WakeupLedger()

    /// Seconds of history kept per owner; the rate covers the last
    /// `rateWindow` complete seconds.
    static let bucketCount = 16
    public static let rateWindow = 10

    public struct Entry: Sendable, Equatable {
        public var owner: String
        public var reason: String
        /// Wakeups since launch (or the last ``reset()``).
        public var count: UInt64
        /// Wakeups per second over the last ``WakeupLedger/rateWindow`` complete seconds.
        public var perSecond: Double
        /// Seconds since the last wakeup of this owner and reason.
        public var secondsSinceLast: Double
    }

    private struct Key: Hashable {
        var owner: String
        var reason: String
    }

    private struct Counter {
        var total: UInt64 = 0
        var lastNanos: UInt64 = 0
        /// Wakeups per whole second, indexed by `second % bucketCount`.
        var buckets = [UInt32](repeating: 0, count: WakeupLedger.bucketCount)
        /// The second `buckets` was last rolled to.
        var second: UInt64 = 0

        mutating func roll(to now: UInt64) {
            guard now > second else { return }
            let stale = min(now - second, UInt64(WakeupLedger.bucketCount))
            for step in 1...stale {
                buckets[Int((second + step) % UInt64(WakeupLedger.bucketCount))] = 0
            }
            second = now
        }

        /// Call after `roll(to: now)`: buckets older than `bucketCount` seconds are zero.
        func rate(at now: UInt64) -> Double {
            var sum: UInt64 = 0
            for back in 1...UInt64(WakeupLedger.rateWindow) where back <= now {
                sum += UInt64(buckets[Int((now - back) % UInt64(WakeupLedger.bucketCount))])
            }
            return Double(sum) / Double(WakeupLedger.rateWindow)
        }
    }

    private let counters = Mutex<[Key: Counter]>([:])
    private let activity = Atomic<UInt64>(0)
    private let uptime: @Sendable () -> UInt64

    /// `uptime` returns monotonic nanoseconds (tests inject a fake).
    public init(uptime: @escaping @Sendable () -> UInt64 = WakeupLedger.systemUptime) {
        self.uptime = uptime
    }

    /// Monotonic nanoseconds (CLOCK_UPTIME_RAW).
    public static let systemUptime: @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Increments on every recorded wakeup.
    public var activitySequence: UInt64 { activity.load(ordering: .relaxed) }

    /// Records one wakeup. Cheap enough for a 120 Hz frame tick.
    public func record(_ owner: String, reason: String = "wake", count: UInt32 = 1) {
        let now = uptime()
        let second = now / 1_000_000_000
        counters.withLock { counters in
            var counter = counters[Key(owner: owner, reason: reason)] ?? Counter(second: second)
            counter.roll(to: second)
            counter.total &+= UInt64(count)
            counter.lastNanos = now
            let slot = Int(second % UInt64(Self.bucketCount))
            counter.buckets[slot] = counter.buckets[slot] &+ count
            counters[Key(owner: owner, reason: reason)] = counter
        }
        activity.add(1, ordering: .relaxed)
    }

    /// Every owner and reason seen, busiest first.
    public func snapshot() -> [Entry] {
        let now = uptime()
        let second = now / 1_000_000_000
        let entries = counters.withLock { counters in
            counters.map { key, value -> Entry in
                var counter = value
                counter.roll(to: second)
                return Entry(owner: key.owner, reason: key.reason, count: counter.total,
                             perSecond: counter.rate(at: second),
                             secondsSinceLast: Double(now &- counter.lastNanos) / 1e9)
            }
        }
        return entries.sorted { ($0.perSecond, $0.count, $1.owner) > ($1.perSecond, $1.count, $0.owner) }
    }

    /// Total wakeups per second over the rate window, all owners.
    public func totalPerSecond() -> Double { snapshot().reduce(0) { $0 + $1.perSecond } }

    public func reset() {
        counters.withLock { $0.removeAll() }
    }
}
