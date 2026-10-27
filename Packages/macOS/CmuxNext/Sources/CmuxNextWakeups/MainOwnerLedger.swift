import CmuxNextCompat
import Darwin
public import Dispatch

/// Per-owner wait and run time of the main-thread scheduler's tasks (plans/cmux-next/chrome-parity/
/// p06-scheduler.md, task 009; machine queue Q12's source): for each owner and class, how long its
/// tasks waited from their post to their start and how long they ran, as p50/p95/p99/max, where
/// they were posted from and the state of their node.
///
/// Chrome keeps the same facts on every task (`base/pending_task.h`: `posted_from`, `queue_time`)
/// and times each one in its sequence manager (`base/task/sequence_manager/task_queue_impl.h`,
/// `TaskTiming`: queue, start and end time), then folds them into histograms off the task's path.
///
/// The main thread writes one fixed slot per finished task into a single-producer ring of atomic
/// words (no lock, no allocation, no string: the posting file is kept as its static literal's
/// address). A full ring counts the record in ``Snapshot/dropped`` and returns: the main thread
/// never waits for the fold. The fold runs off the main thread, on a utility queue the producer
/// wakes once per quarter of the ring (an idle app wakes nothing), and for what is left on the
/// thread that asks for a ``MainTaskBoard/ownerSnapshot()`` (the `debug.main_budget` request): it
/// moves the records into fixed-bucket histograms (four buckets per power of two from 1 µs to
/// about 137 s, so a percentile is within 25 % of the true value; the maximum is exact).
///
/// ```swift
/// let board = MainTaskBoard()                               // its ledger folds in the background
/// budget.run(.visible, owner: owner, posted: MainTaskPost()) { apply() }
/// let owners = board.ownerSnapshot().owners                 // off main; highest run p99 first
/// ```
public final class MainOwnerLedger: Sendable {
    /// Where the fold runs.
    public enum Folding: Sendable {
        /// On a utility queue the producer wakes once per quarter of the ring, and on a snapshot's
        /// thread (the app).
        case background
        /// As ``background``, on `queue` (tests: a serial queue they wait on).
        case queue(DispatchQueue)
        /// Only in ``fold()`` and a snapshot (tests).
        case manual
    }

    /// One owner and class: its tasks' wait and run time, node states and posting locations.
    public struct Owner: Sendable, Equatable {
        /// The owner's name (``MainTaskOwner``).
        public var owner: String
        /// The class its tasks ran in.
        public var workClass: MainWorkClass
        /// Tasks recorded.
        public var tasks: Int
        /// Post to start, over the tasks that were posted (``Distribution/count`` of them).
        public var wait: Distribution
        /// Each task's own run time (nested tasks are their owners' time).
        public var run: Distribution
        /// The run time of all its tasks.
        public var runTotalNanos: UInt64
        /// Tasks per state of their node when they started (``MainTaskPost/NodeState/none``: not posted
        /// with a node).
        public var nodes: [MainTaskPost.NodeState: Int]
        /// Where its posted tasks came from, most tasks first (at most ``MainOwnerLedger/siteLimit``).
        public var sites: [Site]
    }

    /// One posting location (`posted_from`).
    public struct Site: Sendable, Equatable {
        /// The posting file's `#fileID`.
        public var file: String
        /// The posting line.
        public var line: UInt
        /// Tasks posted from here.
        public var tasks: Int

        /// `File.swift:12`.
        public var location: String { "\(file):\(line)" }
    }

    /// A percentile summary of one histogram, in nanoseconds. A percentile is its bucket's upper
    /// bound, capped at ``maxNanos``: from 1 µs up the true value is at most it and at least 4/5 of
    /// it; under 1 µs it reads 1 µs (or the maximum).
    public struct Distribution: Sendable, Equatable {
        /// Samples in the histogram.
        public var count: Int
        /// The median.
        public var p50Nanos: UInt64
        /// The 95th percentile.
        public var p95Nanos: UInt64
        /// The 99th percentile.
        public var p99Nanos: UInt64
        /// The largest sample.
        public var maxNanos: UInt64
    }

    /// What the ledger holds now.
    public struct Snapshot: Sendable, Equatable {
        /// Per owner and class, highest run p99 first.
        public var owners: [Owner]
        /// Records folded since launch or the last ``MainOwnerLedger/reset()``.
        public var recorded: UInt64
        /// Records the full ring refused.
        public var dropped: UInt64
        /// Records written and not folded yet.
        public var pending: Int
    }

    /// The most posting locations a snapshot lists per owner.
    public static let siteLimit = 5

    /// Slots in the ring.
    public let capacity: Int
    private let slots: [Slot]
    /// Next slot to fold; only a folder (holding `folded`) writes it.
    private let head = Atomic<Int>(0)
    /// Next slot to write; only the main thread writes it.
    private let tail = Atomic<Int>(0)
    private let droppedCount = Atomic<UInt64>(0)
    /// A background fold is queued and has not started.
    private let foldQueued = Atomic<Bool>(false)
    /// Where the producer queues a fold (nil: ``Folding/manual``).
    private let foldQueue: DispatchQueue?
    // concurrency-allow: the folders' accumulators (lock carve-out: the main thread never takes it; it is held to fold at most `capacity` records or to copy a snapshot, no I/O under it).
    private let folded = Mutex(Folded())

    /// - Parameters:
    ///   - capacity: Slots in the ring (at least 4, rounded down to a multiple of 4): records past it
    ///     wait for a fold, or are dropped.
    ///   - folding: Where the fold runs (default: in the background).
    public init(capacity: Int = 1024, folding: Folding = .background) {
        self.capacity = max(4, capacity) / 4 * 4
        slots = (0..<self.capacity).map { _ in Slot() }
        switch folding {
        case .background: foldQueue = DispatchQueue.global(qos: .utility)
        case let .queue(queue): foldQueue = queue
        case .manual: foldQueue = nil
        }
    }

    // MARK: Producer (main thread)

    /// A task ended (main thread, the one producer): writes its slot, with its post when it had one.
    ///
    /// - Parameters:
    ///   - workClass: Its class.
    ///   - owner: Its owner's board index.
    ///   - post: Where, when and in which node state it was posted (nil: run without a post).
    ///   - startNanos: When it started.
    ///   - runNanos: Its own run time.
    func ended(_ workClass: MainWorkClass, owner: UInt32, post: MainTaskPost?, startNanos: UInt64, runNanos: UInt64) { // perf-hot: 0.1us main-task-ledger (every scheduled main-thread task)
        assert(pthread_main_np() != 0, "MainOwnerLedger is written on the main thread only")
        let end = tail.load(ordering: .relaxed)
        guard end - head.load(ordering: .acquiring) < capacity else {
            droppedCount.add(1, ordering: .relaxed)
            return
        }
        slots[end % capacity].store(Record(workClass: workClass, owner: owner, post: post, startNanos: startNanos, runNanos: runNanos))
        tail.store(end + 1, ordering: .releasing)
        // Each quarter of the ring wakes the fold once.
        guard let foldQueue, (end + 1) % (capacity / 4) == 0, !foldQueued.exchange(true, ordering: .acquiringAndReleasing) else { return }
        foldQueue.async { [weak self] in
            guard let self else { return }
            foldQueued.store(false, ordering: .releasing)
            fold()
        }
    }

    // MARK: Consumer (any thread but main)

    /// Moves every written record into the histograms, on the caller's thread (never the main
    /// thread: the background fold and the snapshot call it).
    public func fold() {
        folded.withLock { state in
            let start = head.load(ordering: .relaxed)
            let end = tail.load(ordering: .acquiring)
            guard start < end else { return }
            for index in start..<end { state.add(slots[index % capacity].load()) }
            head.store(end, ordering: .releasing)
        }
    }

    /// Clears the histograms and the drop count, and discards the records not folded yet
    /// (`debug.main_budget reset`; off the main thread).
    public func reset() {
        folded.withLock { state in
            head.store(tail.load(ordering: .acquiring), ordering: .releasing)
            state = Folded()
            droppedCount.store(0, ordering: .relaxed)
        }
    }

    /// The folded histograms (records not folded yet are counted in ``Snapshot/pending``).
    ///
    /// - Parameter name: The owner name of a board index.
    func snapshot(name: (UInt32) -> String) -> Snapshot {
        // `head` moves only under the lock, so `recorded + pending + dropped` counts every record
        // written up to these reads once, whatever fold runs meanwhile.
        let (owners, recorded, pending, dropped) = folded.withLock { state in
            let pending = tail.load(ordering: .acquiring) - head.load(ordering: .relaxed)
            return (state.owners, state.recorded, pending, droppedCount.load(ordering: .relaxed))
        }
        let summaries = owners.compactMap { entry -> Owner? in
            let (key, accumulator) = (entry.key, entry.value)
            guard let workClass = MainWorkClass(rawValue: Int(key.workClass)) else { return nil }
            var nodes: [MainTaskPost.NodeState: Int] = [:]
            for state in MainTaskPost.NodeState.allCases where accumulator.nodes[Int(state.rawValue)] > 0 {
                nodes[state] = accumulator.nodes[Int(state.rawValue)]
            }
            return Owner(owner: name(key.owner), workClass: workClass, tasks: accumulator.tasks, wait: accumulator.wait.distribution,
                         run: accumulator.run.distribution, runTotalNanos: accumulator.runTotalNanos, nodes: nodes,
                         sites: Self.sites(accumulator.sites))
        }.sorted {
            ($0.run.p99Nanos, $0.runTotalNanos, $1.owner, $1.workClass.rawValue) > ($1.run.p99Nanos, $1.runTotalNanos, $0.owner, $0.workClass.rawValue)
        }
        return Snapshot(owners: summaries, recorded: recorded, dropped: dropped, pending: max(0, pending))
    }

    /// The top sites by task count, named by file (two copies of one `#fileID` literal are one site).
    private static func sites(_ counts: [SiteKey: Int]) -> [Site] {
        var byName: [String: [UInt: Int]] = [:]
        for (key, tasks) in counts { byName[key.fileName, default: [:]][UInt(key.line), default: 0] += tasks }
        let sites = byName.flatMap { file, lines in lines.map { Site(file: file, line: $0.key, tasks: $0.value) } }
        return Array(sites.sorted { ($0.tasks, $1.file, $1.line) > ($1.tasks, $0.file, $0.line) }.prefix(siteLimit))
    }

    // MARK: Storage

    /// One finished task, as the main thread writes it and a folder reads it back.
    struct Record: Sendable {
        var owner: UInt32 = 0
        var workClass: UInt8 = 0
        var node: UInt8 = MainTaskPost.NodeState.none.rawValue
        var posted = false
        /// The posting file's `#fileID` literal: its address and UTF-8 length (0: none).
        var file: UInt = 0
        var fileLength: UInt32 = 0
        var line: UInt32 = 0
        var waitNanos: UInt64 = 0
        var runNanos: UInt64 = 0

        init() {}

        init(workClass: MainWorkClass, owner: UInt32, post: MainTaskPost?, startNanos: UInt64, runNanos: UInt64) {
            self.owner = owner
            self.workClass = UInt8(truncatingIfNeeded: workClass.rawValue)
            self.runNanos = runNanos
            guard let post else { return }
            posted = true
            node = post.node.rawValue
            let file = post.site.file
            if file.hasPointerRepresentation {
                self.file = UInt(bitPattern: file.utf8Start)
                fileLength = UInt32(truncatingIfNeeded: file.utf8CodeUnitCount)
            }
            line = UInt32(clamping: post.site.line)
            waitNanos = startNanos > post.enqueueNanos ? startNanos - post.enqueueNanos : 0
        }
    }

    /// One ring slot: the record's fields as atomic words (relaxed: `tail` and `head` order them).
    private final class Slot: Sendable {
        /// `owner << 32 | class << 24 | node << 16 | posted`.
        private let meta = Atomic<UInt64>(0)
        private let file = Atomic<UInt>(0)
        /// `fileLength << 32 | line`.
        private let lengthLine = Atomic<UInt64>(0)
        private let wait = Atomic<UInt64>(0)
        private let run = Atomic<UInt64>(0)

        func store(_ record: Record) {
            let packed = UInt64(record.owner) << 32 | UInt64(record.workClass) << 24 | UInt64(record.node) << 16 | (record.posted ? 1 : 0)
            meta.store(packed, ordering: .relaxed)
            file.store(record.file, ordering: .relaxed)
            lengthLine.store(UInt64(record.fileLength) << 32 | UInt64(record.line), ordering: .relaxed)
            wait.store(record.waitNanos, ordering: .relaxed)
            run.store(record.runNanos, ordering: .relaxed)
        }

        func load() -> Record {
            let packed = meta.load(ordering: .relaxed)
            let site = lengthLine.load(ordering: .relaxed)
            var record = Record()
            record.owner = UInt32(truncatingIfNeeded: packed >> 32)
            record.workClass = UInt8(truncatingIfNeeded: packed >> 24)
            record.node = UInt8(truncatingIfNeeded: packed >> 16)
            record.posted = packed & 1 == 1
            record.file = file.load(ordering: .relaxed)
            record.fileLength = UInt32(truncatingIfNeeded: site >> 32)
            record.line = UInt32(truncatingIfNeeded: site)
            record.waitNanos = wait.load(ordering: .relaxed)
            record.runNanos = run.load(ordering: .relaxed)
            return record
        }
    }

    private struct Key: Hashable, Sendable {
        var owner: UInt32
        var workClass: UInt8
    }

    /// A posting location by its literal's address (the fold builds no string).
    private struct SiteKey: Hashable, Sendable {
        var file: UInt
        var fileLength: UInt32
        var line: UInt32

        /// The `#fileID` the address holds (a static literal: valid for the process's life).
        var fileName: String {
            guard let start = UnsafePointer<UInt8>(bitPattern: file) else { return "?" }
            return String(decoding: UnsafeBufferPointer(start: start, count: Int(fileLength)), as: UTF8.self)
        }
    }

    private struct Accumulator: Sendable {
        var tasks = 0
        var wait = Histogram()
        var run = Histogram()
        var runTotalNanos: UInt64 = 0
        var nodes = [Int](repeating: 0, count: MainTaskPost.NodeState.allCases.count)
        var sites: [SiteKey: Int] = [:]

        mutating func add(_ record: Record) {
            tasks += 1
            run.add(record.runNanos)
            runTotalNanos &+= record.runNanos
            if Int(record.node) < nodes.count { nodes[Int(record.node)] += 1 }
            guard record.posted else { return }
            wait.add(record.waitNanos)
            sites[SiteKey(file: record.file, fileLength: record.fileLength, line: record.line), default: 0] += 1
        }
    }

    private struct Folded: Sendable {
        var owners: [Key: Accumulator] = [:]
        var recorded: UInt64 = 0

        mutating func add(_ record: Record) {
            recorded &+= 1
            let key = Key(owner: record.owner, workClass: record.workClass)
            owners[key, default: Accumulator()].add(record)
        }
    }
}

extension MainOwnerLedger {
    /// Fixed-bucket nanosecond histogram: bucket 0 holds values under 1 µs (2^10 ns), then four
    /// buckets per power of two up to 2^37 ns (about 137 s), then one overflow bucket. The owner
    /// ledger and the daemon store's drain cost (`DrainCost`) count in it.
    public struct Histogram: Sendable, Equatable {
        static let minExponent = 10
        static let maxExponent = 36
        /// The buckets: one under 1 µs, four per power of two, one overflow.
        public static let bucketCount = 1 + (maxExponent - minExponent + 1) * 4 + 1

        /// Samples per bucket.
        public private(set) var counts = [Int](repeating: 0, count: Histogram.bucketCount)
        /// Samples counted.
        public private(set) var count = 0
        /// The longest sample, in nanoseconds.
        public private(set) var maxNanos: UInt64 = 0

        /// An empty histogram.
        public init() {}

        /// Counts one sample of `nanos` nanoseconds.
        public mutating func add(_ nanos: UInt64) {
            counts[Self.bucket(of: nanos)] += 1
            count += 1
            maxNanos = max(maxNanos, nanos)
        }

        /// Counts `duration` in whole nanoseconds (a negative one as zero).
        public mutating func add(_ duration: Duration) {
            add(duration.nanosecondCount)
        }

        /// The bucket `nanos` lands in.
        public static func bucket(of nanos: UInt64) -> Int {
            guard nanos >= 1 << minExponent else { return 0 }
            let exponent = 63 - nanos.leadingZeroBitCount
            guard exponent <= maxExponent else { return bucketCount - 1 }
            let sub = Int((nanos >> UInt64(exponent - 2)) & 3)
            return 1 + (exponent - minExponent) * 4 + sub
        }

        /// The smallest value of `bucket`.
        public static func lowerBound(of bucket: Int) -> UInt64 {
            guard bucket > 0 else { return 0 }
            guard bucket < bucketCount - 1 else { return 1 << UInt64(maxExponent + 1) }
            let exponent = minExponent + (bucket - 1) / 4
            return UInt64(4 + (bucket - 1) % 4) << UInt64(exponent - 2)
        }

        /// The first value past `bucket` (`UInt64.max` for the overflow bucket).
        public static func upperBound(of bucket: Int) -> UInt64 {
            guard bucket < bucketCount - 1 else { return .max }
            return lowerBound(of: bucket + 1)
        }

        /// The value at or below which `fraction` of the samples lie: its bucket's upper bound,
        /// capped at the largest sample (0 with no samples).
        public func percentile(_ fraction: Double) -> UInt64 {
            guard count > 0 else { return 0 }
            // The epsilon keeps 0.99 x 100 at rank 99 (its double product can round past 99).
            let rank = max(1, Int((fraction * Double(count) - 1e-9).rounded(.up)))
            var seen = 0
            for (bucket, inBucket) in counts.enumerated() where inBucket > 0 {
                seen += inBucket
                if seen >= rank { return min(Self.upperBound(of: bucket), maxNanos) }
            }
            return maxNanos
        }

        /// The count, p50, p95, p99 and max of the samples.
        public var distribution: MainOwnerLedger.Distribution {
            MainOwnerLedger.Distribution(count: count, p50Nanos: percentile(0.5), p95Nanos: percentile(0.95), p99Nanos: percentile(0.99),
                                         maxNanos: maxNanos)
        }
    }
}
