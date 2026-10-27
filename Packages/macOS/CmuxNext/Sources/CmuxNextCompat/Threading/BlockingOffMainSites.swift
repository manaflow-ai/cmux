#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Atomics

/// The call sites of one off-main violation context of ``BlockingViolationTable`` (``BlockingContext/pool``,
/// ``BlockingContext/cpuLane`` or ``BlockingContext/laneSync``), recorded from many threads at once: the index,
/// the per-site atomics, the ring of new sites for the drain and the overflow count (Debug and bench-checks
/// builds).
///
/// A repeat of a known site is one lock-free probe (``BlockingSharedSiteIndex``). Only a new site takes the
/// insert lock, to take its id and push to the ring, so the ring has one producer at a time, as it requires.
final class BlockingOffMainSites: Sendable {
    /// Probed by any thread with no lock; inserted only with ``insertLock`` held.
    private let index: BlockingSharedSiteIndex
    // concurrency-allow: taken only by an off-main violation at a site the lock-free probe did not find (a new site, at most siteLimit per launch and context): one probe, one index insert and one ring push, no wait or stack walk inside (lock carve-out).
    private let insertLock = Mutex(())
    /// Each site's count and wall times.
    let counters: BlockingSiteCounters
    /// Pushed only with ``insertLock`` held (one producer at a time), popped by the drain.
    let ring: BlockingPendingRing
    private let overflowCount = UnsafeAtomic<Int>.create(0)

    /// Makes the sites of one context.
    ///
    /// - Parameters:
    ///   - siteLimit: The most sites the context records; past it a call counts in ``overflow``.
    ///   - pendingLimit: The most new sites waiting for the drain.
    init(siteLimit: Int, pendingLimit: Int) {
        index = BlockingSharedSiteIndex(capacity: siteLimit)
        counters = BlockingSiteCounters(capacity: siteLimit)
        ring = BlockingPendingRing(capacity: pendingLimit)
    }

    deinit {
        overflowCount.destroy()
    }

    /// The id of a known site, with no lock.
    func find(_ key: BlockingSiteKey) -> Int? {
        index.find(key)
    }

    /// Whether every site id is taken.
    var isFull: Bool { index.isFull }

    /// Records `pending`, whose stack the caller walked, as the site `key`: probes again under the insert lock
    /// (another thread may have just inserted it), takes its id and pushes it to the ring. Returns the id and
    /// whether the site is new (the caller wakes the drain), or nil when the index or the ring is full.
    func insert(_ pending: BlockingPendingCall, key: BlockingSiteKey) -> (id: Int, isNew: Bool)? {
        var pending = pending
        return insertLock.withLock { _ in
            if let id = index.find(key) { return (id, false) }
            guard let id = index.nextID else { return nil }
            pending.site = id
            guard ring.push(pending) else { return nil }
            index.insert(key)
            return (id, true)
        }
    }

    /// Counts one call not recorded as a site.
    func countOverflow() {
        overflowCount.wrappingIncrement(ordering: .relaxed)
    }

    /// Calls not recorded as a site: the index was full, or the ring held its limit of new sites.
    var overflow: Int { overflowCount.load(ordering: .relaxed) }
}
#endif
