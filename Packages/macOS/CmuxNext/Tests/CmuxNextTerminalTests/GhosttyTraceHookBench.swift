import CmuxNextCompat
import CmuxNextMetrics
@testable import CmuxNextTerminal
import CmuxNextTrace
@testable import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// The cost per frame of the Ghostty trace hook's contents mark (p09-observability-090, done check 3 of
/// plans/cmux-next/chrome-parity/p09-observability.md: "the cost of the hook contents mark per frame is printed"),
/// called the way ghostty-next calls it (the IOSurface handoff, or the presented frame with
/// `GHOSTTY_RENDERER_FRAMES`):
/// - between echo samples, the Release steady state: the hook stays set for `key.echo_frame` sampling and each
///   frame pays two loads. It must make no heap allocation.
/// - while the probe records with no press open (`CMUX_TYPING_FLOWS`, `cmux trace record --keys`).
/// - the frame that shows a parsed press's echo: the mark that closes the press, timed one call at a time.
///
/// A measurement, not a CI test (as TraceEventBench): the suite runs only with `CMUX_BENCH=1`, in a Release build,
/// on the fleet.
///
/// ```
/// CMUX_BENCH=1 swift test -c release --filter GhosttyTraceHookBench
/// ```
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_BENCH"] == "1"))
struct GhosttyTraceHookBench {
    private static let frames = 1_280_000
    private static let batch = 64
    private static let echoes = 20_000

    /// A runtime with its own heap ring attached and every category on.
    private static func runtime() -> TraceRuntime {
        let runtime = TraceRuntime(role: .app)
        runtime.attach(TraceRing(records: 1 << 16, role: .app))
        runtime.setCategories(.all)
        return runtime
    }

    /// Marks frame `seq` of the rig's surface shown, as the linked libghostty does.
    private static func frameShown(_ rig: GhosttyTraceHookTests.Rig, seq: UInt64) {
        if GhosttyTraceHook.presentsFrames {
            rig.present(frameID: seq)
        } else {
            rig.call(.contentsHandoff, seq: seq)
        }
    }

    /// Sorted nanoseconds per frame of each batch of `batch` frames, and the allocations of the timed batches.
    private static func timeFrames(_ rig: GhosttyTraceHookTests.Rig) throws -> (nanos: [Double], mallocs: Int) {
        let batches = frames / batch
        let samples = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: batches)
        defer { samples.deallocate() }
        var seq: UInt64 = 0
        func run() {
            for sample in 0 ..< batches {
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                for _ in 0 ..< batch {
                    seq &+= 1
                    frameShown(rig, seq: seq)
                }
                samples[sample] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- start
            }
        }
        run() // warm
        let mallocs = try HookBenchMallocs.hooked { HookBenchMallocs.count(run) }
        return (samples.map { Double($0) / Double(batch) }.sorted(), mallocs)
    }

    private static func percentile(_ sorted: [Double], _ quantile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * quantile + 0.5))]
    }

    private static func line(_ name: String, _ nanos: [Double], _ mallocs: Int, per unit: String) -> String {
        String(format: "hook-bench: %@: p50 %.2f ns, p99 %.2f ns, max %.1f ns (%ld samples); mallocs %ld (%@)",
               name, percentile(nanos, 0.5), percentile(nanos, 0.99), nanos.last ?? 0, nanos.count, mallocs, unit)
    }

    @Test func aFrameBetweenEchoSamples() throws {
        let trace = Self.runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace, echoFrames: Metrics(runtime: trace))
        let rig = GhosttyTraceHookTests.Rig(trace: trace, probe: probe)
        rig.hook.refreshDemand()
        try #require(rig.hook.isInstalled && probe.samplesEchoFrames, "echo sampling keeps the hook set")
        let (nanos, mallocs) = try Self.timeFrames(rig)
        print(Self.line("contents mark, between echo samples", nanos, mallocs, per: "per frame, batches of \(Self.batch)"))
        #expect(mallocs == 0, "a frame between echo samples allocated")
    }

    @Test func aFrameWhileTheProbeRecordsWithNoPressOpen() throws {
        let trace = Self.runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace)
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = GhosttyTraceHookTests.Rig(trace: trace, probe: probe)
        rig.hook.refreshDemand()
        try #require(rig.hook.isInstalled && probe.isRecording)
        let (nanos, mallocs) = try Self.timeFrames(rig)
        print(Self.line("contents mark, recording, no press open", nanos, mallocs, per: "per frame, batches of \(Self.batch)"))
    }

    /// The frame that shows a parsed press's echo: one mark per press, each timed alone, less the cost of the
    /// clock read pair around it.
    @Test func theFrameThatShowsAnEcho() throws {
        let trace = Self.runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace)
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = GhosttyTraceHookTests.Rig(trace: trace, probe: probe)
        rig.hook.refreshDemand()
        try #require(rig.hook.isInstalled)

        var clockPair = UInt64.max
        for _ in 0 ..< 10_000 {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            clockPair = min(clockPair, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- start)
        }
        var nanos: [Double] = []
        nanos.reserveCapacity(Self.echoes)
        var mallocs = 0, closed = 0
        try HookBenchMallocs.hooked {
            for index in 0 ..< Self.echoes {
                try Self.parsedPress(probe, on: rig.key)
                var elapsed: UInt64 = 0
                mallocs += HookBenchMallocs.count {
                    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    Self.frameShown(rig, seq: UInt64(index + 1))
                    elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- start
                }
                nanos.append(Double(elapsed &- min(elapsed, clockPair)))
                probe.turnDidEnd()
                closed += probe.takePresentCommits().count
            }
        }
        nanos.sort()
        print(Self.line("contents mark of an echo", nanos, mallocs, per: "per mark, clock pair \(clockPair) ns removed")
              + String(format: "; %.2f mallocs per mark", Double(mallocs) / Double(Self.echoes)))
        #expect(closed == Self.echoes, "each frame closed its press")
    }

    /// One key press on `key` whose echo was parsed (GhosttyTraceHookTests' press).
    private static func parsedPress(_ probe: TypingLatencyProbe, on key: TypingLatencyProbe.SurfaceKey) throws {
        _ = probe.keyDown(eventTimestamp: 0)
        probe.keyReachedTerminal(key, display: 7)
        probe.terminalTookKey()
        probe.mark(.dispatchEnd)
        probe.inputWritten(on: key)
        let flow = try #require(probe.openFlow)
        probe.mark(.socketSubmit, flow: flow)
        probe.outputDecoded(flow: flow)
        probe.mark(.outputReceived, flow: flow)
        probe.mark(.outputParsed, flow: flow)
    }
}

/// libmalloc's allocation hook type (`malloc_logger_t`): type flags, three arguments, the result, frames to skip.
private typealias HookBenchMallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// Counts the heap allocations of the calling thread inside ``count(_:)``, through libmalloc's `malloc_logger`
/// hook (as TraceEventBench's counter, which lives in another test target).
nonisolated private enum HookBenchMallocs {
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
        let hook = symbol.assumingMemoryBound(to: HookBenchMallocLogger?.self)
        _ = key // made before the hook runs: its lazy initializer is not counted
        let previous = hook.pointee
        hook.pointee = countHookBenchMalloc
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
nonisolated private func countHookBenchMalloc(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    let allocate: UInt32 = 2 // MALLOC_LOG_TYPE_ALLOCATE (libmalloc stack_logging.h)
    guard type & allocate != 0, let counter = pthread_getspecific(HookBenchMallocs.key) else { return }
    counter.assumingMemoryBound(to: Int.self).pointee += 1
}
