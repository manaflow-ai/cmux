import CmuxNextCompat
@testable import CmuxNextSignposts
import CmuxNextSignpostsC
import Darwin
import Testing

/// libmalloc's allocation hook type (`malloc_logger_t`): type flags, three arguments, the result, frames to skip.
private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// The hook's state: the C hook captures nothing, so it reads these.
nonisolated private enum MallocTally {
    /// The mach port of the thread being counted; 0 (`MACH_PORT_NULL`, never a thread) while none is.
    static let thread = Atomic<UInt32>(0)
    /// Allocations that thread made since counting began.
    static let allocations = Atomic<Int>(0)
    /// Where a control allocation's address goes, so the optimizer cannot remove the allocation.
    static let sink = Atomic<UInt>(0)
}

/// libmalloc calls the hook on every allocation and free of every zone, on every thread (the hook
/// MallocStackLogging and Instruments' Allocations install); this one counts the allocations (and reallocations)
/// of the counted thread. It allocates nothing itself.
nonisolated private func tallyMalloc(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    let allocate: UInt32 = 2  // MALLOC_LOG_TYPE_ALLOCATE
    guard type & allocate != 0, pthread_mach_thread_np(pthread_self()) == MallocTally.thread.load(ordering: .relaxed) else { return }
    _ = MallocTally.allocations.add(1, ordering: .relaxed)
}

/// Counts the heap allocations the calling thread makes in a block, other threads left out, so suites running in
/// parallel do not count (malloc zone statistics alone are process-wide).
private struct ThreadMallocs {
    /// libmalloc's `malloc_logger` variable.
    private let hook: UnsafeMutablePointer<MallocLogger?>

    /// Nil when libmalloc exports no hook.
    init?() {
        // RTLD_DEFAULT, a C macro Swift does not import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        hook = symbol.assumingMemoryBound(to: MallocLogger?.self)
        // The statics are made here, before the hook reads them.
        MallocTally.thread.store(0, ordering: .relaxed)
        MallocTally.allocations.store(0, ordering: .relaxed)
        MallocTally.sink.store(0, ordering: .relaxed)
    }

    /// Runs `body` and returns how many allocations this thread made in it.
    func count(_ body: () -> Void) -> Int {
        MallocTally.allocations.store(0, ordering: .relaxed)
        MallocTally.thread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
        let previous = hook.pointee
        hook.pointee = tallyMalloc
        body()
        hook.pointee = previous
        MallocTally.thread.store(0, ordering: .relaxed)
        return MallocTally.allocations.load(ordering: .relaxed)
    }
}

/// The per-key signposts make no heap allocation (p09-observability task 007): `key.frame` begins and ends on every
/// key for every user, recorder attached or not, and `key.flow` marks each hop of a sampled press. Run in Release
/// (`swift test -c release --filter KeyFrameSignpostAllocationTests`): the optimized code is what ships.
@Suite("KeyFrameSignpostAllocation", .serialized)
struct KeyFrameSignpostAllocationTests {
    /// `count` key.frame pairs: both targets, ages with and without a timestamp, committed and missed ends.
    private func keyFramePairs(_ signposter: Signposter, count: Int) {
        for index in 0..<count {
            let target: KeyFrameSignpost.Target = index & 1 == 0 ? .view : .terminal
            let age: Int64 = index % 3 == 0 ? -1 : Int64(index) * 37
            let interval = signposter.begin(.keyToFrame, target: target, ageMicros: age)
            signposter.end(.keyToFrame, interval, index % 5 == 0 ? .missed : .committed)
        }
    }

    private func flowHops(_ signposter: Signposter, count: Int) {
        for index in 0..<count {
            signposter.flowHop(index & 1 == 0 ? "app.key.dispatch" : "app.frame.commit", flow: UInt64(index) | 1 << 40,
                               ageMicroseconds: index % 3 == 0 ? -1 : Int64(index))
        }
    }

    @Test func theCounterSeesThisThreadsMallocs() throws {
        let mallocs = try #require(ThreadMallocs(), "libmalloc exports malloc_logger")
        let cMallocs = mallocs.count {
            let pointer = malloc(64)
            MallocTally.sink.store(UInt(bitPattern: pointer), ordering: .relaxed)
            free(pointer)
        }
        #expect(cMallocs >= 1, "a C malloc is counted, so a zero below is not a hook that never ran")
        let swiftMallocs = mallocs.count {
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
            MallocTally.sink.store(UInt(bitPattern: pointer), ordering: .relaxed)
            pointer.deallocate()
        }
        #expect(swiftMallocs >= 1, "a Swift runtime allocation (swift_slowAlloc, every class instance's path) is counted")
    }

    @Test func aThousandKeyFramePairsMakeNoMallocs() throws {
        let mallocs = try #require(ThreadMallocs(), "libmalloc exports malloc_logger")
        let signposter = Signposter(category: .key, mirror: SignpostMetricKitMirror())
        try #require(signposter.isEnabled, "the key category's signposts are on, so the pairs reach os_signpost")
        keyFramePairs(signposter, count: 16)  // the key log is made once, at the first emit
        let made = mallocs.count { keyFramePairs(signposter, count: 1_000) }
        #expect(made == 0)
    }

    @Test func aThousandKeyFlowHopsMakeNoMallocs() throws {
        let mallocs = try #require(ThreadMallocs(), "libmalloc exports malloc_logger")
        let signposter = Signposter(category: .key, mirror: SignpostMetricKitMirror())
        try #require(signposter.isEnabled)
        flowHops(signposter, count: 16)
        let made = mallocs.count { flowHops(signposter, count: 1_000) }
        #expect(made == 0)
    }

    @Test func theCSignpostsUseTheCatalogsNames() {
        #expect(String(cString: cmux_signpost_subsystem()) == SignpostCategory.subsystem)
        #expect(String(cString: cmux_signpost_key_category()) == SignpostCategory.key.rawValue)
        #expect(String(cString: cmux_signpost_key_frame_name()) == SignpostName.keyToFrame.description)
        #expect(String(cString: cmux_signpost_key_flow_name()) == SignpostName.keyFlow.description)
    }

    @Test func theAgeIsTheKeysWaitInMicrosecondsAndMinusOneWithoutATimestamp() {
        #expect(KeyFrameSignpost.ageMicros(eventTimestamp: 10, now: 10.0125) == 12_500)
        #expect(KeyFrameSignpost.ageMicros(eventTimestamp: 0, now: 10) == -1)
        #expect(KeyFrameSignpost.ageMicros(eventTimestamp: 11, now: 10) == 0, "a clock skew never gives a negative age")
    }
}
