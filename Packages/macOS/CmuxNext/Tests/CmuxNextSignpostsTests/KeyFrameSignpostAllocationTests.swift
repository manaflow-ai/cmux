import CmuxNextCompat
import CmuxNextMetrics
@testable import CmuxNextSignposts
import CmuxNextSignpostsC
@testable import CmuxNextTrace
import CoreFoundation
import Darwin
import Foundation
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

/// The ring records a test runtime publishes while no ring is attached, in order.
private final class StubRecords: Sendable {
    private let records = Mutex<[TraceRuntime.StubRecord]>([])

    var all: [TraceRuntime.StubRecord] { records.withLock { $0 } }

    /// A runtime that publishes into this log, with `categories` on.
    func runtime(_ categories: SignpostCategory...) -> TraceRuntime {
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
            records.withLock { $0.append(record) }
        })
        runtime.setCategoryMask(categories.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) })
        return runtime
    }
}

/// The key and stall signposts make no heap allocation (p09-observability task 007): `key.frame` begins and ends on
/// every key for every user, `key.flow` marks each hop of a sampled press, and the main-thread scheduler opens a
/// `stall.main_task` interval per task and a `stall.over_budget` event per task past its budget. Each count runs with
/// the category's trace ring flag on and a real ring attached, so the ring write is counted too. Run in Release
/// (`swift test -c release --filter KeyFrameSignpostAllocationTests`): the optimized code is what ships.
@Suite("KeyFrameSignpostAllocation", .serialized)
struct KeyFrameSignpostAllocationTests {
    private let mirror = SignpostMetricKitMirror()

    /// A signposter for `category` whose ring records go to a real heap ring with `category` on, and whose runtime
    /// has a metrics store, so a key's `key.frame` sample is counted too (task 054).
    private func ringSignposter(_ category: SignpostCategory) -> Signposter {
        let runtime = TraceRuntime(role: .app)
        runtime.attach(TraceRing(records: 4_096, role: .app))
        runtime.setCategoryMask(1 << UInt64(category.traceBit))
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "dev", osVersion: "26.1.0",
                                     hardwareClass: "Mac16,10", buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))
        MetricsStore(role: .app, profile: profile).attach(to: runtime)
        return Signposter(category: category, mirror: mirror, trace: runtime)
    }

    /// `count` key-downs through ``KeyFrameSignpost``, both targets, with and without a timestamp, ended by the
    /// observer's callout as one, two or three keys per turn, committed and missed.
    // The drivers below loop on an index, not `for`: a Debug build runs a range's `IndexingIterator` unspecialized in
    // libswiftCore, whose read coroutine heap-allocates its frame, so the counted loop would add
    // allocations of its own.
    private func keyDowns(_ keyFrames: KeyFrameSignpost, count: Int) {
        var index = 0
        while index < count {
            defer { index += 1 }
            let target: KeyFrameSignpost.Target = index & 1 == 0 ? .view : .terminal
            if index % 4 == 0 {
                keyFrames.begin(target: target, eventTimestamp: 0)
            } else {
                keyFrames.begin(target: target, eventTimestamp: 10, now: 10 + Double(index) * 0.000_037)
            }
            if index % 3 == 2 || index % 5 == 0 {
                keyFrames.runLoopReached(index % 7 == 0 ? .afterWaiting : .beforeWaiting)
            }
        }
        keyFrames.runLoopReached(.exit)
    }

    /// Every hop, made once: `allCases` builds a new array on each read in a Debug build.
    private let hops = KeyFlowHop.allCases

    private func flowHops(_ signposter: Signposter, count: Int) {
        var index = 0
        while index < count {
            defer { index += 1 }
            signposter.flowHop(hops[index % hops.count], flow: UInt64(index) | 1 << 40,
                               ageMicroseconds: index % 3 == 0 ? -1 : Int64(index))
        }
    }

    /// The owners a task names: a small `String` (stored inline), a literal too long to be small, and a native
    /// heap `String` made before counting (an interned owner name).
    private let owners = ["Control.frames", "FrameBatcher.sidebar.rowPatches",
                          "Control." + String(repeating: "workspace.", count: 3)]
    /// `MainWorkClass.description`'s names (CmuxNextWakeups, which this target does not import).
    private let classes = ["input", "frame", "visible", "automation", "background"]

    private func stallTasks(_ signposter: Signposter, count: Int) {
        var index = 0
        while index < count {
            defer { index += 1 }
            let task = signposter.begin(.stallMainTask, taskClass: classes[index % classes.count],
                                        owner: owners[index % owners.count],
                                        classID: UInt8(index % classes.count), ownerID: UInt32(index % owners.count + 1))
            signposter.end(.stallMainTask, task)
        }
    }

    private func overBudgetEvents(_ signposter: Signposter, count: Int) {
        var index = 0
        while index < count {
            defer { index += 1 }
            signposter.event(.stallOverBudget, taskClass: classes[index % classes.count], owner: owners[index % owners.count],
                             classID: UInt8(index % classes.count), ownerID: UInt32(index % owners.count + 1),
                             ownNanos: 5_000_000 + UInt64(index) * 1_000, budgetNanos: 4_000_000)
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

    @Test func aThousandKeyDownsThroughKeyFrameSignpostMakeNoMallocs() throws {
        let mallocs = try #require(ThreadMallocs(), "libmalloc exports malloc_logger")
        let keyFrames = KeyFrameSignpost(signposter: ringSignposter(.key))
        keyDowns(keyFrames, count: 64)  // the key log, this thread's ring state and the first chunk are made once
        let made = mallocs.count { keyDowns(keyFrames, count: 1_000) }
        #expect(made == 0)
        #expect(keyFrames.openCount == 0)
    }

    @Test func aThousandKeyFlowHopsMakeNoMallocs() throws {
        let mallocs = try #require(ThreadMallocs(), "libmalloc exports malloc_logger")
        let signposter = ringSignposter(.key)
        flowHops(signposter, count: 64)
        let made = mallocs.count { flowHops(signposter, count: 1_000) }
        #expect(made == 0)
    }

    @Test func aThousandStallMainTasksMakeNoMallocs() throws {
        let mallocs = try #require(ThreadMallocs(), "libmalloc exports malloc_logger")
        let signposter = ringSignposter(.stall)
        stallTasks(signposter, count: 64)
        let made = mallocs.count { stallTasks(signposter, count: 1_000) }
        #expect(made == 0)
    }

    @Test func aThousandStallOverBudgetEventsMakeNoMallocs() throws {
        let mallocs = try #require(ThreadMallocs(), "libmalloc exports malloc_logger")
        let signposter = ringSignposter(.stall)
        overBudgetEvents(signposter, count: 64)
        let made = mallocs.count { overBudgetEvents(signposter, count: 1_000) }
        #expect(made == 0)
    }

    @Test("key.frame decodes as AB then AE with one id, the target and age in the begin, how it ended in the end")
    func keyFrameRecordsDecodeAsAnAsyncSlice() throws {
        let log = StubRecords()
        let key = Signposter(category: .key, mirror: mirror, trace: log.runtime(.key))
        let terminal = key.begin(.keyToFrame, target: .terminal, ageMicros: 1_500)
        let view = key.begin(.keyToFrame, target: .view, ageMicros: -1)
        #expect(terminal.isTraced && view.isTraced)
        key.end(.keyToFrame, terminal, .missed)
        key.end(.keyToFrame, view, .committed)
        let records = log.all
        try #require(records.count == 4)
        #expect(records.map(\.phase) == [.asyncBegin, .asyncBegin, .asyncEnd, .asyncEnd])
        #expect(records.allSatisfy { $0.name == SignpostName.keyToFrame.rawValue && $0.flags.contains(.asyncID) })
        #expect(records[0].arg1 == records[2].arg1 && records[1].arg1 == records[3].arg1)
        #expect(records[0].arg1 != records[1].arg1, "two open keys share an async id")
        #expect(records[0].arg0 & 0xFF == 2 && records[1].arg0 & 0xFF == 1, "terminal is 2, view is 1")
        #expect(records[0].arg0 >> 40 == 1_500 && records[1].arg0 >> 40 == 0xFF_FFFF, "the age in us, all ones without one")
        #expect(records[2].arg0 == Signposter.EndCode.missed && records[3].arg0 == Signposter.EndCode.ended)
    }

    @Test("With the key category off, a key.frame pair writes no ring record")
    func keyFrameWithTheCategoryOffWritesNothing() {
        let log = StubRecords()
        let key = Signposter(category: .key, mirror: mirror, trace: log.runtime())
        let interval = key.begin(.keyToFrame, target: .view, ageMicros: 10)
        #expect(!interval.isTraced)
        key.end(.keyToFrame, interval, .committed)
        #expect(log.all.isEmpty)
    }

    @Test("KeyFrameSignpost ends every open key at the observer's next callout: committed, or missed after a wake")
    func keyFrameSignpostEndsOpenKeysAtTheCallout() throws {
        let log = StubRecords()
        let key = Signposter(category: .key, mirror: mirror, trace: log.runtime(.key))
        let keyFrames = KeyFrameSignpost(signposter: key, capacity: 2)
        keyFrames.begin(target: .view, eventTimestamp: 0)
        keyFrames.begin(target: .terminal, eventTimestamp: 0)
        keyFrames.begin(target: .view, eventTimestamp: 0)
        #expect(keyFrames.openCount == 2, "a key past the capacity records no interval")
        keyFrames.runLoopReached(.beforeWaiting)
        #expect(keyFrames.openCount == 0)
        keyFrames.runLoopReached(.beforeWaiting)
        keyFrames.begin(target: .view, eventTimestamp: 0)
        keyFrames.runLoopReached(.afterWaiting)
        let records = log.all
        #expect(records.map(\.phase) == [.asyncBegin, .asyncBegin, .asyncEnd, .asyncEnd, .asyncBegin, .asyncEnd])
        #expect(records.filter { $0.phase == .asyncEnd }.map(\.arg0)
            == [Signposter.EndCode.ended, Signposter.EndCode.ended, Signposter.EndCode.missed])
    }

    @Test("Installed on the main run loop, KeyFrameSignpost ends a key at the end of the turn, once")
    func keyFrameSignpostEndsAtTheRunLoopTurn() {
        let log = StubRecords()
        let keyFrames = KeyFrameSignpost(signposter: Signposter(category: .key, mirror: mirror, trace: log.runtime(.key)))
        keyFrames.installOnMainRunLoop()
        keyFrames.begin(target: .terminal, eventTimestamp: 0)
        #expect(keyFrames.openCount == 1)
        pollingTurn()
        #expect(keyFrames.openCount == 0)
        pollingTurn()
        #expect(log.all.map(\.phase) == [.asyncBegin, .asyncEnd])
        #expect(log.all.last?.arg0 == Signposter.EndCode.ended)
    }

    @Test("stall.main_task is a thread slice with the class and owner ids; stall.over_budget an instant with the times")
    func stallRecords() throws {
        let log = StubRecords()
        let stall = Signposter(category: .stall, mirror: mirror, trace: log.runtime(.stall))
        let task = stall.begin(.stallMainTask, taskClass: "visible", owner: "Control.frames", classID: 2, ownerID: 9)
        stall.end(.stallMainTask, task)
        stall.event(.stallOverBudget, taskClass: "visible", owner: "Control.frames", classID: 2, ownerID: 9,
                    ownNanos: 6_250_000, budgetNanos: 4_000_000)
        let records = log.all
        try #require(records.count == 3)
        #expect(records.map(\.phase) == [.begin, .end, .instant])
        #expect(records[0].name == SignpostName.stallMainTask.rawValue && records[1].name == records[0].name)
        #expect(records[0].arg0 == 9 | 3 << 32, "owner 9, class position 2 as code 3")
        #expect(records[2].name == SignpostName.stallOverBudget.rawValue)
        #expect(records[2].arg0 & 0xFF_FFFF_FFFF == 9 | 3 << 32)
        #expect(records[2].arg0 >> 40 == 4_000, "the budget in us")
        #expect(records[2].arg1 == 6_250_000, "the task's own time in ns")
    }

    @Test func theCSignpostsUseTheCatalogsNames() {
        #expect(String(cString: cmux_signpost_subsystem()) == SignpostCategory.subsystem)
        #expect(String(cString: cmux_signpost_key_category()) == SignpostCategory.key.rawValue)
        #expect(String(cString: cmux_signpost_stall_category()) == SignpostCategory.stall.rawValue)
        #expect(String(cString: cmux_signpost_key_frame_name()) == SignpostName.keyToFrame.description)
        #expect(String(cString: cmux_signpost_key_flow_name()) == SignpostName.keyFlow.description)
        #expect(String(cString: cmux_signpost_stall_task_name()) == SignpostName.stallMainTask.description)
        #expect(String(cString: cmux_signpost_stall_over_budget_name()) == SignpostName.stallOverBudget.description)
    }

    @Test func everyKeyFlowHopsStaticNameIsItsRawValue() {
        for hop in KeyFlowHop.allCases {
            #expect(hop.staticName.description == hop.rawValue, "\(hop)")
        }
    }

    @Test func theAgeIsTheKeysWaitInMicrosecondsAndMinusOneWithoutATimestamp() {
        #expect(KeyFrameSignpost.ageMicros(eventTimestamp: 10, now: 10.0125) == 12_500)
        #expect(KeyFrameSignpost.ageMicros(eventTimestamp: 0, now: 10) == -1)
        #expect(KeyFrameSignpost.ageMicros(eventTimestamp: 11, now: 10) == 0, "a clock skew never gives a negative age")
    }

    /// Runs one main run-loop turn that polls and exits without waiting: only the exit activity fires. A mode with
    /// no source returns before notifying observers, so a far-future timer keeps the default mode non-empty.
    private func pollingTurn() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        CFRunLoopTimerInvalidate(timer)
    }
}

