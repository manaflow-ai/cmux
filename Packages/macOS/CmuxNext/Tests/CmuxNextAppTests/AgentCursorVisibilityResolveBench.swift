import CmuxNextAgentCursorVisibility
import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// The main-thread cost of one `AgentCursorVisibilityResolver.resolve` call, the
/// work the cursor host does for each agent input event (a streamed agent pointer
/// move included) and per frame of pane motion while a target is tracked, in
/// nanoseconds per call: p50, p95, p99 and max over samples of a batch of
/// resolves that rotate through schemas/agent-cursor-visibility/vectors.json,
/// through a kept resolver as `AgentCursorVisibilitySource` holds one. It also
/// prints the heap allocations per resolve of the kept resolver and of the
/// one-off static call. A measurement, not a gate: the A/B of the Swift rules
/// against the Rust call (B9) runs it alone on an exclusive host with the
/// resolver of each arm.
///
/// ```
/// CMUX_AGENT_CURSOR_VISIBILITY_BENCH=1 swift test -c release --filter AgentCursorVisibilityResolveBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_AGENT_CURSOR_VISIBILITY_BENCH"] == "1"))
struct AgentCursorVisibilityResolveBench {
    /// Resolves timed together per sample: one resolve is a few timer ticks
    /// (about 42 ns each on Apple silicon), so a sample of one cannot tell two
    /// fast resolvers apart; a sample is ns per call over the batch.
    private static let batch = 1_000
    private static let samples = 400

    @Test func nanosecondsPerResolve() throws {
        let cases = try AgentCursorVisibilityVectorTests.vectors().cases
        var resolver = AgentCursorVisibilityResolver()
        var sink = 0
        for item in cases {  // warm, and grows the kept resolver's arrays to the largest vector
            if case .visible = resolver.resolve(target: item.target, in: item.snapshot) { sink &+= 1 }
            if case .visible = AgentCursorVisibilityResolver.resolve(target: item.target, in: item.snapshot) { sink &+= 1 }
        }
        // The control's address goes into the sink, so a release build cannot drop or stack-promote it.
        let control = ResolveMallocProbe.allocations {
            let block = UnsafeMutableRawPointer.allocate(byteCount: 64 + cases.count, alignment: 16)
            sink &+= Int(bitPattern: block) & 1
            block.deallocate()
        }
        let loop = ResolveMallocProbe.allocations { for item in cases { sink &+= item.target.utf8.count & 1 } } ?? 0
        let kept = ResolveMallocProbe.allocations {
            for item in cases {
                if case .visible = resolver.resolve(target: item.target, in: item.snapshot) { sink &+= 1 }
            }
        }
        let oneOff = ResolveMallocProbe.allocations {
            for item in cases {
                if case .visible = AgentCursorVisibilityResolver.resolve(target: item.target, in: item.snapshot) { sink &+= 1 }
            }
        }
        // No hook, or a hook that missed the control: print that, and still time the resolves.
        let probed = (control ?? 0) > 0
        func perResolve(_ count: Int?) -> String {
            guard probed, let count else { return "not counted (malloc_logger saw no control allocation)" }
            return String(format: "%.2f", Double(count - loop) / Double(cases.count))
        }

        var perCall: [Double] = []
        perCall.reserveCapacity(Self.samples)
        var next = 0
        for _ in 0..<Self.samples {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<Self.batch {
                // Every vector in turn, so a batch covers every rule path.
                let item = cases[next]
                next = next + 1 == cases.count ? 0 : next + 1
                if case .visible = resolver.resolve(target: item.target, in: item.snapshot) { sink &+= 1 }
            }
            perCall.append(Double(DispatchTime.now().uptimeNanoseconds - start) / Double(Self.batch))
        }
        perCall.sort()
        func quantile(_ q: Double) -> Double { perCall[min(perCall.count - 1, Int(Double(perCall.count) * q))] }
        func ns(_ value: Double) -> String { String(format: "%.1f", value) }
        print("agent-cursor-visibility bench: macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
              + "\(Self.samples) samples of \(Self.batch) resolves over \(cases.count) vectors, ns per call: "
              + "p50 \(ns(quantile(0.5))) ns, p95 \(ns(quantile(0.95))) ns, p99 \(ns(quantile(0.99))) ns, "
              + "max \(ns(perCall.last ?? 0)) ns (sink \(sink & 1))")
        print("agent-cursor-visibility allocations per resolve: kept resolver \(perResolve(kept)), "
              + "one-off call \(perResolve(oneOff)) (over \(cases.count) vectors, loop alone \(loop))")
        #expect(perCall.count == Self.samples)
    }
}

// MARK: Counting the main thread's allocations

/// libmalloc's allocation hook type (`malloc_logger_t`): type flags, three arguments, the result, frames to skip.
private typealias ResolveMallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// The hook's state: the C hook captures nothing, so it reads these.
nonisolated private struct ResolveMallocTally {
    /// The mach port of the thread being counted; 0 (`MACH_PORT_NULL`) while none is.
    static let thread = Atomic<UInt32>(0)
    /// Allocations that thread made since counting began.
    static let allocations = Atomic<Int>(0)
}

/// Counts the counted thread's allocations (and reallocations); allocates nothing itself.
nonisolated private func tallyResolveMalloc(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    let allocate: UInt32 = 2  // MALLOC_LOG_TYPE_ALLOCATE
    guard type & allocate != 0, pthread_mach_thread_np(pthread_self()) == ResolveMallocTally.thread.load(ordering: .relaxed) else { return }
    _ = ResolveMallocTally.allocations.add(1, ordering: .relaxed)
}

/// How many heap allocations the calling thread makes in `body`, through libmalloc's `malloc_logger` hook
/// (as TipActionRunAllocationTests counts); nil when libmalloc exports no hook.
nonisolated private struct ResolveMallocProbe {
    static func allocations(_ body: () -> Void) -> Int? {
        // RTLD_DEFAULT, a C macro Swift does not import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let hook = symbol.assumingMemoryBound(to: ResolveMallocLogger?.self)
        ResolveMallocTally.allocations.store(0, ordering: .relaxed)
        ResolveMallocTally.thread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
        let previous = hook.pointee
        hook.pointee = tallyResolveMalloc
        body()
        hook.pointee = previous
        ResolveMallocTally.thread.store(0, ordering: .relaxed)
        return ResolveMallocTally.allocations.load(ordering: .relaxed)
    }
}
