import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// The overhead of one histogram record (p09-observability-090, done check 3 of
/// plans/cmux-next/chrome-parity/p09-observability.md: at most 10 ns per record): with no store attached, into
/// the store's heap block, into its `MAP_SHARED` file after adoption, and from 8 threads at once into one
/// histogram (the shared bucket, count and sum words). Each case prints its ns per record at p50 and p99 and
/// asserts that it makes no heap allocation.
///
/// Chrome measures `UMA_HISTOGRAM_*` the same way, as a perf test that prints numbers and gates nothing
/// (base/metrics/histogram_perftest.cc). A measurement, not a CI test: the suite runs only with
/// `CMUX_BENCH=1`, in a Release build, on the fleet.
///
/// ```
/// CMUX_BENCH=1 swift test -c release --no-parallel --filter MetricsRecordBench
/// ```
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_BENCH"] == "1"))
struct MetricsRecordBench {
    private static let ids: [HistogramID] = [.mainTurn, .frameInterval, .keyFrame(.view), .smoothnessDroppedPercent(.motion)]

    private static func store(_ runtime: TraceRuntime) -> MetricsStore {
        let profile = MetricsProfile(appVersion: "1.2.3", buildNumber: "45", channel: "nightly", osVersion: "26.1.0",
                                     hardwareClass: "Mac16,10", bootSessionUUID: Array(0 ..< 16), buildUUID: Array(16 ..< 32),
                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))
        let store = MetricsStore(role: .app, profile: profile, pid: 4242)
        store.attach(to: runtime)
        return store
    }

    @Test func aRecordWithNoStoreDoesNothing() throws {
        let metrics = Metrics(runtime: TraceRuntime(role: .app))
        let ids = Self.ids
        let result = try MetricsBench.run("metrics record, no store") { index in
            metrics.record(ids[index & 3], Int64(index & 0xFFFF))
        }
        print(result.line)
        #expect(result.mallocs == 0, "a record with no store allocated")
    }

    @Test func aRecordIntoTheHeapBlockAndTheFile() throws {
        let runtime = TraceRuntime(role: .app)
        let store = Self.store(runtime)
        let metrics = Metrics(runtime: runtime)
        let ids = Self.ids
        let heap = try MetricsBench.run("metrics record, heap block") { index in
            metrics.record(ids[index & 3], Int64(index & 0xFFFF))
        }
        print(heap.line)
        #expect(heap.mallocs == 0, "a record into the heap block allocated")

        let directory = NSTemporaryDirectory() + "cmux-metrics-bench-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        _ = try #require(store.adoptFile(directory: directory), "the store adopts its file")
        let file = try MetricsBench.run("metrics record, MAP_SHARED file") { index in
            metrics.record(ids[index & 3], Int64(index & 0xFFFF))
        }
        print(file.line)
        #expect(file.mallocs == 0, "a record into the file allocated")
    }

    /// 8 threads record into one histogram at once: the worst case for its shared bucket, count and sum words.
    @Test func recordsFromEightThreadsIntoOneHistogram() throws {
        let threads = 8
        let runtime = TraceRuntime(role: .app)
        _ = Self.store(runtime)
        let metrics = Metrics(runtime: runtime)
        let single = try MetricsBench.run("metrics record, one histogram, 1 thread (reference)") { index in
            metrics.record(.frameInterval, Int64(index & 0xFFFF))
        }
        let contended = try MetricsBench.runContended(threads, "metrics record, one histogram, \(threads) threads") { _, index in
            metrics.record(.frameInterval, Int64(index & 0xFFFF))
        }
        print(single.line)
        print(contended.line + String(format: "; p99 / 1-thread p99 = %.2f", contended.p99 / max(single.p99, 0.001)))
        #expect(contended.mallocs == 0, "a contended record allocated")
    }
}

/// The timing loop and the allocation count of the metrics bench (as TraceEventBench's `TraceBench`, which lives
/// in another test target): each sample is one batch of ``batch`` records timed as a whole on
/// `CLOCK_UPTIME_RAW`; the percentiles are of the per-record time of each batch.
struct MetricsBench {
    static let batch = 64
    static let batches = 20_000
    static let warmBatches = 500

    /// One case's numbers.
    struct Numbers {
        let name: String
        /// Sorted nanoseconds per record, one per batch.
        let nanos: [Double]
        let threads: Int
        let mallocs: Int

        var p50: Double { Self.percentile(nanos, 0.50) }
        var p99: Double { Self.percentile(nanos, 0.99) }

        var line: String {
            String(format: "metrics-bench: %@: p50 %.2f ns, p99 %.2f ns, max %.1f ns (%ld threads x %ld batches of %ld); mallocs %ld",
                   name, p50, p99, nanos.last ?? 0, threads, MetricsBench.batches, MetricsBench.batch, mallocs)
        }

        static func percentile(_ sorted: [Double], _ quantile: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * quantile + 0.5))]
        }
    }

    /// Times `operation` on the calling thread.
    static func run(_ name: String, _ operation: (Int) -> Void) throws -> Numbers {
        let samples = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: batches)
        defer { samples.deallocate() }
        timeBatches(warmBatches, into: samples, operation)
        let mallocs = try MetricsBenchMallocs.hooked {
            MetricsBenchMallocs.count { timeBatches(batches, into: samples, operation) }
        }
        return Numbers(name: name, nanos: perOperation(samples), threads: 1, mallocs: mallocs)
    }

    /// Times `operation(thread, index)` on `threads` new threads that start their timed batches together.
    static func runContended(_ threads: Int, _ name: String, _ operation: @escaping @Sendable (Int, Int) -> Void) throws -> Numbers {
        let samples = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: batches * threads)
        let mallocs = UnsafeMutableBufferPointer<Int>.allocate(capacity: threads)
        defer {
            samples.deallocate()
            mallocs.deallocate()
        }
        // Addresses, not pointers, cross into the threads (each writes only its own range).
        let samplesAddress = UInt(bitPattern: samples.baseAddress), mallocsAddress = UInt(bitPattern: mallocs.baseAddress)
        let ready = BenchReady()
        try MetricsBenchMallocs.hooked {
            BenchThreads.run(threads) { thread in
                guard let all = UnsafeMutablePointer<UInt64>(bitPattern: samplesAddress),
                      let counts = UnsafeMutablePointer<Int>(bitPattern: mallocsAddress) else { return }
                let own = UnsafeMutableBufferPointer(start: all + thread * MetricsBench.batches, count: MetricsBench.batches)
                MetricsBench.timeBatches(MetricsBench.warmBatches, into: own) { operation(thread, $0) }
                ready.count.add(1, ordering: .relaxed)
                // wakeup-allow: bounded: a start barrier of the bench's own threads, which all arrive within microseconds.
                while ready.count.load(ordering: .relaxed) < threads {}
                counts[thread] = MetricsBenchMallocs.count {
                    MetricsBench.timeBatches(MetricsBench.batches, into: own) { operation(thread, $0) }
                }
            }
        }
        return Numbers(name: name, nanos: perOperation(samples), threads: threads, mallocs: mallocs.reduce(0, +))
    }

    @inline(__always)
    private static func timeBatches(_ count: Int, into samples: UnsafeMutableBufferPointer<UInt64>, _ operation: (Int) -> Void) {
        var index = 0
        for sample in 0 ..< count {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for _ in 0 ..< batch {
                operation(index)
                index &+= 1
            }
            samples[sample % samples.count] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- start
        }
    }

    private static func perOperation(_ samples: UnsafeMutableBufferPointer<UInt64>) -> [Double] {
        samples.map { Double($0) / Double(batch) }.sorted()
    }
}

/// The start barrier the contended case's threads share.
private final class BenchReady: Sendable {
    let count = Atomic<Int>(0)
}

/// Runs `body(index)` on `count` new threads at once and returns when all have exited.
private enum BenchThreads {
    static func run(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) {
        var threads: [pthread_t] = []
        for index in 0 ..< count {
            let context = Unmanaged.passRetained(BenchThreadBody { body(index) }).toOpaque()
            var thread: pthread_t?
            let created = pthread_create(&thread, nil, { context in
                Unmanaged<BenchThreadBody>.fromOpaque(context).takeRetainedValue().run()
                return nil
            }, context)
            if created == 0, let thread {
                threads.append(thread)
            } else {
                Unmanaged<BenchThreadBody>.fromOpaque(context).release()
                Issue.record("pthread_create failed: \(created)")
            }
        }
        for thread in threads {
            pthread_join(thread, nil)
        }
    }
}

private final class BenchThreadBody: Sendable {
    let run: @Sendable () -> Void

    init(_ run: @escaping @Sendable () -> Void) {
        self.run = run
    }
}

/// libmalloc's allocation hook type (`malloc_logger_t`): type flags, three arguments, the result, frames to skip.
private typealias MetricsBenchMallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// Counts the heap allocations of the threads inside ``count(_:)``, through libmalloc's `malloc_logger` hook:
/// a counted thread's thread-specific value is its own counter, so any number of threads count at once.
nonisolated private enum MetricsBenchMallocs {
    /// The thread-specific key whose value is the counting thread's counter (nil: not counting).
    static let key: pthread_key_t = {
        var key = pthread_key_t()
        _ = pthread_key_create(&key, nil)
        return key
    }()

    /// Where the control allocation's address goes, so the optimizer keeps the allocation.
    nonisolated(unsafe) static var sink: UnsafeMutableRawPointer?

    /// Runs `body` with the hook installed, after checking that the hook sees this thread's allocations.
    /// `malloc_logger` is one word per process and this hook reads only this bench's key: it fails when another
    /// hook is in at the start or replaced this one before `body` returned (a test of another target running in parallel).
    static func hooked<T>(_ body: () throws -> T) throws -> T {
        // RTLD_DEFAULT, a C macro Swift does not import.
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger"), "libmalloc exports malloc_logger")
        let hook = symbol.assumingMemoryBound(to: MetricsBenchMallocLogger?.self)
        _ = key // made before the hook runs: its lazy initializer is not counted
        let installed = hook.pointee != nil
        try #require(!installed, "another malloc_logger is installed: run the benches alone (swift test --no-parallel)")
        hook.pointee = countMetricsBenchMalloc
        defer { if holdsOwn(hook) { hook.pointee = nil } }
        let control = count {
            sink = malloc(64)
            free(sink)
        }
        try #require(control >= 1, "malloc_logger saw no allocation on this thread: the bench cannot count here")
        let result = try body()
        try #require(holdsOwn(hook), "another malloc_logger replaced the bench's hook while it counted: run the benches alone (swift test --no-parallel)")
        return result
    }

    /// Whether `hook` holds this bench's counting function.
    private static func holdsOwn(_ hook: UnsafeMutablePointer<MetricsBenchMallocLogger?>) -> Bool {
        unsafeBitCast(hook.pointee, to: UInt.self) == unsafeBitCast(countMetricsBenchMalloc as MetricsBenchMallocLogger, to: UInt.self)
    }

    /// The allocations the calling thread makes in `body` while the hook is installed.
    static func count(_ body: () -> Void) -> Int {
        let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        counter.initialize(to: 0)
        defer { counter.deallocate() }
        _ = pthread_setspecific(key, counter)
        body()
        _ = pthread_setspecific(key, nil)
        return counter.pointee
    }
}

/// The hook: one count per allocation of a counting thread; it allocates nothing itself.
nonisolated private func countMetricsBenchMalloc(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    let allocate: UInt32 = 2 // MALLOC_LOG_TYPE_ALLOCATE (libmalloc stack_logging.h)
    guard type & allocate != 0, let counter = pthread_getspecific(MetricsBenchMallocs.key) else { return }
    counter.assumingMemoryBound(to: Int.self).pointee += 1
}
