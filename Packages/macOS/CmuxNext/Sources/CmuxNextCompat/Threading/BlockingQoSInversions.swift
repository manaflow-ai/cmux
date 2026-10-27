#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Darwin
internal import Dispatch

/// The QoS inversions the waiting seams record (Debug and bench-checks builds; Release compiles them out): a thread
/// waited on a queue whose QoS is below its own (``BlockingQoSInversion``). Any thread records, the main thread
/// included, since an inversion is about the two classes, not the thread.
///
/// The sites are a ``BlockingOffMainSites``: a repeat of a known site is one lock-free probe and one atomic add;
/// only a new site takes its short insert lock and pushes to its ring, and the drain queue publishes it. No stack
/// is walked and no sink is called: an inversion is a lab count (`debug.blocking` `inversions`, the perf lab's
/// `qos.inversions`), not a hang-report violation.
final class BlockingQoSInversions: Sendable {
    /// The most inversion sites one launch records; past it an inversion only counts in ``overflow``.
    static let siteLimit = 64

    private let sites = BlockingOffMainSites(siteLimit: BlockingQoSInversions.siteLimit,
                                             pendingLimit: BlockingQoSInversions.siteLimit)
    // concurrency-allow: written only by the drain queue (one append per new site, at most siteLimit per launch) and copied by readers (debug.blocking); a recording thread never takes it (lock carve-out).
    private let published = Mutex<[Published]>([])

    private struct Published: Sendable {
        var id: Int
        var location: String
        var waiter: ThreadQoS
        var target: ThreadQoS
    }

    /// Counts one wait of a `waiter`-class thread on a `target`-class queue at `fileID`:`line`, which the caller
    /// found inverted. Returns true for a new site the drain has to publish (the caller wakes it).
    func record(waiter: ThreadQoS, target: ThreadQoS, fileID: StaticString, line: UInt) -> Bool {
        let key = BlockingSiteKey(fileID: fileID, line: line)
        if let id = sites.find(key) {
            sites.counters.add(site: id, nanos: nil)
            return false
        }
        guard !sites.isFull else {
            sites.countOverflow()
            return false
        }
        var pending = BlockingPendingCall(kind: .priorityInversion, site: -1, fileID: fileID, line: line)
        pending.waiter = waiter
        pending.target = target
        guard let recorded = sites.insert(pending, key: key) else {
            sites.countOverflow()
            return false
        }
        sites.counters.add(site: recorded.id, nanos: nil)
        return recorded.isNew
    }

    /// Publishes the new sites (drain queue only).
    func drain() {
        while let pending = sites.ring.pop() {
            let site = Published(id: pending.site, location: "\(pending.fileID):\(pending.line)",
                                 waiter: pending.waiter, target: pending.target)
            published.withLock { $0.append(site) }
        }
    }

    /// The published sites, in the order each first reached the drain, with their counts now.
    var inversions: [BlockingQoSInversion] {
        published.withLock { $0 }.map { site in
            BlockingQoSInversion(location: site.location, waiter: site.waiter, target: site.target,
                                 count: sites.counters.read(site: site.id).count)
        }
    }

    /// Inversions not recorded as a site: the table was full, or its ring held its limit of new sites.
    var overflow: Int { sites.overflow }

    /// Zeroes every site's count; the sites stay known.
    func resetCounts() {
        sites.counters.reset()
    }
}

extension BlockingViolationTable {
    /// A waiting seam (``Dispatch/DispatchQueue/blockingSync(fileID:line:execute:)``) is about to wait on `queue`:
    /// when the calling thread's QoS is above the queue's (a queue with a class), the wait is one inversion at
    /// `fileID`:`line`. A queue made without a class runs at its submitters' class, so it is never an inversion.
    /// Off an inversion it is two class reads and one compare.
    @usableFromInline @inline(never)
    static func qosWait(onto queue: DispatchQueue, fileID: StaticString, line: UInt) {
        let target = ThreadQoS(queue.qos.qosClass)
        let waiter = ThreadQoS.current
        guard waiter.isInverted(waitingOn: target) else { return }
        let table = active
        if table.qosInversions.record(waiter: waiter, target: target, fileID: fileID, line: line) {
            table.wakeDrain()
        }
    }
}

extension ThreadQoS {
    /// The calling thread's class now (`qos_class_self()`); a class dispatch does not name (maintenance) reads as
    /// unspecified.
    static var current: ThreadQoS {
        DispatchQoS.QoSClass(rawValue: qos_class_self()).map { ThreadQoS($0) } ?? .unspecified
    }

    /// Whether a thread of this class waiting on a queue of `target`'s class is an inversion: `target` has a class
    /// and it is below this one.
    func isInverted(waitingOn target: ThreadQoS) -> Bool {
        target != .unspecified && target.priority < priority
    }

    /// The kernel tier's order, lowest first (`THREAD_QOS_*`); unspecified is 0.
    private var priority: Int {
        switch self {
        case .unspecified: 0
        case .maintenance: 1
        case .background: 2
        case .utility: 3
        case .default: 4
        case .userInitiated: 5
        case .userInteractive: 6
        }
    }
}
#endif
