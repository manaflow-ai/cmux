import CmuxNextCompat
import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// The overhead of a Swift trace point and a hang-watch scope (p09-observability-090, done check 3 of
/// plans/cmux-next/chrome-parity/p09-observability.md): a point whose category is off, a ring write on one
/// thread and on 8 threads at once, a write under an interned name, and a scope open and close. Each case prints
/// its ns per operation at p50 and p99 and asserts that it makes no heap allocation.
///
/// Chrome measures its trace macros the same way, as a perf test that prints numbers and gates nothing
/// (base/trace_event/trace_event_unittest.cc and base/tracing/perfetto_task_runner perftests). A measurement,
/// not a CI test: the suite runs only with `CMUX_BENCH=1`, in a Release build, on the fleet.
///
/// ```
/// CMUX_BENCH=1 swift test -c release --filter TraceEventBench
/// ```
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_BENCH"] == "1"))
struct TraceEventBench {
    /// The catalog id the cases write; the bench ring has no catalog, so any id decodes the same.
    private static let name: UInt16 = 46
    /// `frame` (bit 10): off in the black box, so it is the disabled point.
    private static let offBit: UInt8 = 10
    /// `action` (bit 0): on in every case that writes.
    private static let onBit: UInt8 = 0
    private static let interned = TraceRuntime.InternedName("action.bench_interned", categoryBit: 0)

    /// A runtime with its own heap ring attached and `categories` on.
    private static func runtime(_ categories: TraceCategories) -> TraceRuntime {
        let runtime = TraceRuntime(role: .app)
        runtime.attach(TraceRing(records: 1 << 16, role: .app))
        runtime.setCategories(categories)
        return runtime
    }

    @Test func aDisabledPointIsOneLoadAndABranch() throws {
        let runtime = Self.runtime(.blackBox)
        try #require(!runtime.isEnabled(categoryBit: Self.offBit))
        let result = try TraceBench.run("trace disabled point") { index in
            _ = runtime.write(name: Self.name, categoryBit: Self.offBit, phase: .instant, arg0: UInt64(index))
        }
        print(result.line)
        #expect(result.mallocs == 0, "a trace point that is off allocated")
        #expect(runtime.ring?.records().isEmpty == true, "a trace point that is off wrote a record")
    }

    @Test func aRingWriteOnOneThread() throws {
        let runtime = Self.runtime(.all)
        let result = try TraceBench.run("trace ring write, 1 thread") { index in
            _ = runtime.write(name: Self.name, categoryBit: Self.onBit, phase: .instant, arg0: UInt64(index))
        }
        print(result.line)
        #expect(result.mallocs == 0, "a ring write allocated")
    }

    @Test func aRingWriteUnderAnInternedName() throws {
        let runtime = Self.runtime(.all)
        let result = try TraceBench.run("trace ring write, interned name") { index in
            _ = runtime.write(Self.interned, phase: .instant, arg0: UInt64(index))
        }
        print(result.line)
        #expect(result.mallocs == 0, "an interned write allocated")
    }

    /// 8 threads write into one ring at once (each owns its chunk; the chunk claim is the shared step). Done
    /// check 3 wants their p99 within 20% of one thread's: the line prints the ratio.
    @Test func ringWritesOnEightThreadsAtOnce() throws {
        let threads = 8
        let runtime = Self.runtime(.all)
        let single = try TraceBench.run("trace ring write, 1 thread (reference)") { index in
            _ = runtime.write(name: Self.name, categoryBit: Self.onBit, phase: .instant, arg0: UInt64(index))
        }
        let contended = try TraceBench.runContended(threads, "trace ring write, \(threads) threads") { thread, index in
            _ = runtime.write(name: Self.name, categoryBit: Self.onBit, phase: .instant, arg0: UInt64(thread) << 32 | UInt64(index))
        }
        print(single.line)
        print(contended.line + String(format: "; p99 / 1-thread p99 = %.2f", contended.p99 / max(single.p99, 0.001)))
        #expect(contended.mallocs == 0, "a contended ring write allocated")
    }

    /// A hang-watch scope (Chrome's `WatchHangsInScope`) opened and closed on a registered thread, with no monitor.
    @Test func aHangWatchScopeOpensAndCloses() throws {
        let watch = HangWatch()
        let thread = watch.registerThread(.io, name: "bench.scope")
        defer { watch.unregister(thread) }
        let result = try TraceBench.run("hang-watch scope open and close") { _ in
            let scope = watch.watch(thread, deadline: .seconds(10))
            scope.close()
        }
        print(result.line)
        #expect(result.mallocs == 0, "a hang-watch scope allocated")
    }
}

/// The timing loop and the allocation count of the trace benches: each sample is one batch of
/// ``batch`` operations timed as a whole on `CLOCK_UPTIME_RAW` (the trace clock), so the clock read is
/// amortized; the percentiles are of the per-operation time of each batch.
struct TraceBench {
    static let batch = 64
    static let batches = 20_000
    static let warmBatches = 500

    /// One case's numbers.
    struct Numbers {
        let name: String
        /// Sorted nanoseconds per operation, one per batch.
        let nanos: [Double]
        let threads: Int
        let mallocs: Int

        var p50: Double { Self.percentile(nanos, 0.50) }
        var p99: Double { Self.percentile(nanos, 0.99) }

        var line: String {
            String(format: "trace-bench: %@: p50 %.2f ns, p99 %.2f ns, max %.1f ns (%ld threads x %ld batches of %ld); mallocs %ld",
                   name, p50, p99, nanos.last ?? 0, threads, TraceBench.batches, TraceBench.batch, mallocs)
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
        let mallocs = try TraceBenchMallocs.hooked {
            TraceBenchMallocs.count { timeBatches(batches, into: samples, operation) }
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
        let ready = SharedCount()
        try TraceBenchMallocs.hooked {
            runOnThreads(threads) { thread in
                guard let all = UnsafeMutablePointer<UInt64>(bitPattern: samplesAddress),
                      let counts = UnsafeMutablePointer<Int>(bitPattern: mallocsAddress) else { return }
                let own = UnsafeMutableBufferPointer(start: all + thread * TraceBench.batches, count: TraceBench.batches)
                // The thread's first write makes its ring state: warm before counting.
                TraceBench.timeBatches(TraceBench.warmBatches, into: own) { operation(thread, $0) }
                ready.value.add(1, ordering: .relaxed)
                // wakeup-allow: bounded: a start barrier of the bench's own threads, which all arrive within microseconds.
                while ready.value.load(ordering: .relaxed) < threads {}
                counts[thread] = TraceBenchMallocs.count { TraceBench.timeBatches(TraceBench.batches, into: own) { operation(thread, $0) } }
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

/// libmalloc's allocation hook type (`malloc_logger_t`): type flags, three arguments, the result, frames to skip.
private typealias BenchMallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// Counts the heap allocations of the threads inside ``count(_:)``, through libmalloc's `malloc_logger` hook
/// (the one malloc stack logging uses, as HistogramTests' tally): a counted thread's thread-specific value
/// is its own counter, so any number of threads count at once and other threads cost one lookup.
nonisolated enum TraceBenchMallocs {
    /// The thread-specific key whose value is the counting thread's counter (nil: not counting).
    static let key: pthread_key_t = {
        var key = pthread_key_t()
        _ = pthread_key_create(&key, nil)
        return key
    }()

    /// Where the control allocation's address goes, so the optimizer keeps the allocation.
    nonisolated(unsafe) static var sink: UnsafeMutableRawPointer?

    /// Runs `body` with the hook installed, after checking that the hook sees this thread's allocations.
    static func hooked<T>(_ body: () throws -> T) throws -> T {
        // RTLD_DEFAULT, a C macro Swift does not import.
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger"), "libmalloc exports malloc_logger")
        let hook = symbol.assumingMemoryBound(to: BenchMallocLogger?.self)
        _ = key // made before the hook runs: its lazy initializer is not counted
        let previous = hook.pointee
        hook.pointee = countBenchMalloc
        defer { hook.pointee = previous }
        let control = count {
            sink = malloc(64)
            free(sink)
        }
        try #require(control >= 1, "malloc_logger saw no allocation on this thread: the bench cannot count here")
        return try body()
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
nonisolated private func countBenchMalloc(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    let allocate: UInt32 = 2 // MALLOC_LOG_TYPE_ALLOCATE (libmalloc stack_logging.h)
    guard type & allocate != 0, let counter = pthread_getspecific(TraceBenchMallocs.key) else { return }
    counter.assumingMemoryBound(to: Int.self).pointee += 1
}
