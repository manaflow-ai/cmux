import CmuxNextCompat
@testable import CmuxNextWakeups
import Darwin
import Testing

/// libmalloc's allocation hook type (`malloc_logger_t`): type flags, three arguments, the result, frames to skip.
private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// The hook's state: the C hook captures nothing, so it reads these.
nonisolated private enum CrashKeyMallocTally {
    /// The mach port of the thread being counted; 0 (`MACH_PORT_NULL`) while none is.
    static let thread = Atomic<UInt32>(0)
    /// Allocations that thread made since counting began.
    static let allocations = Atomic<Int>(0)
}

/// Counts the counted thread's allocations (and reallocations); allocates nothing itself.
nonisolated private func tallyCrashKeyMalloc(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    let allocate: UInt32 = 2  // MALLOC_LOG_TYPE_ALLOCATE
    guard type & allocate != 0, pthread_mach_thread_np(pthread_self()) == CrashKeyMallocTally.thread.load(ordering: .relaxed) else { return }
    _ = CrashKeyMallocTally.allocations.add(1, ordering: .relaxed)
}

/// How many heap allocations the calling thread makes in `body` (other threads left out), through libmalloc's
/// `malloc_logger` hook; nil when libmalloc exports no hook.
private func threadAllocations(_ body: () -> Void) -> Int? {
    // RTLD_DEFAULT, a C macro Swift does not import.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
    let hook = symbol.assumingMemoryBound(to: MallocLogger?.self)
    CrashKeyMallocTally.allocations.store(0, ordering: .relaxed)
    CrashKeyMallocTally.thread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
    let previous = hook.pointee
    hook.pointee = tallyCrashKeyMalloc
    body()
    hook.pointee = previous
    CrashKeyMallocTally.thread.store(0, ordering: .relaxed)
    return CrashKeyMallocTally.allocations.load(ordering: .relaxed)
}

/// The app's crash keys (Chrome's crash_key.h): preallocated words written and read with
/// atomics. The crash path and the hang reporter read them, so neither a write nor a read may allocate or lock.
@Suite(.serialized) struct CrashKeySlotsTests {
    @Test func settingScopingAndReadingKeysMakesNoAllocation() throws {
        let keys = CrashKeySlots()
        let action = CrashKeySlots.stableKey("workspace.new")
        // Warm-up outside the count: the first call of a generic or a witness may resolve metadata.
        keys.withKey(.actionID, action) { _ = keys.snapshot() }
        let control = threadAllocations { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        var read = CrashKeySlots.Snapshot()
        let measured = try #require(threadAllocations {
            keys.set(.daemonEpoch, 3)
            keys.set(.paneKind, CrashKeySlots.PaneKind.terminal.rawValue)
            keys.withKey(.actionID, action) {
                keys.noteHung(CrashKeySlots.HungThread(port: 4242, kind: 2))
                read = CrashKeySlots.read(wordsAt: keys.wordsAddress)
                _ = keys.value(.actionID)
                _ = read.hungThreadCount
            }
            keys.clearHung(port: 4242)
            _ = keys.snapshot()
        })
        #expect(measured == 0, "the crash keys made \(measured) heap allocations")
        #expect(read.actionID == action)
        #expect(read.daemonEpoch == 3)
        #expect(read.hungThread(at: 0) == CrashKeySlots.HungThread(port: 4242, kind: 2))
    }

    /// The crash path's own read: the record line written straight from the block's words (what
    /// `CrashReporter.recordCrashKeys()` runs in a fatal-signal handler), and from a snapshot.
    @Test func writingTheCrashRecordMakesNoAllocation() throws {
        let keys = CrashKeySlots()
        keys.set(.actionID, .max)
        keys.set(.paneKind, CrashKeySlots.PaneKind.browser.rawValue)
        keys.set(.cefState, CrashKeySlots.CEFState.inPump.rawValue)
        keys.set(.daemonEpoch, 12)
        keys.noteHung(CrashKeySlots.HungThread(port: 4242, kind: 3))
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: CrashKeySlots.maxRecordBytes, alignment: 8)
        defer { buffer.deallocate() }
        // Warm-up outside the count, as the app's launch does (`CrashReporter.attachCrashKeys`).
        _ = CrashKeySlots.writeRecord(wordsAt: keys.wordsAddress, into: buffer)
        _ = keys.snapshot().writeRecord(into: buffer)
        var fromWords = 0, fromSnapshot = 0
        let measured = try #require(threadAllocations {
            fromWords = CrashKeySlots.writeRecord(wordsAt: keys.wordsAddress, into: buffer)
            fromSnapshot = keys.snapshot().writeRecord(into: buffer)
        })
        #expect(measured == 0, "writing the crash record made \(measured) heap allocations")
        #expect(fromWords == fromSnapshot)
        let line = String(decoding: UnsafeRawBufferPointer(rebasing: buffer[..<fromSnapshot]), as: UTF8.self)
        #expect(line == "crash_keys action_id=\(UInt64.max) pane_kind=2 cef_state=3 daemon_epoch=12 hung_threads=1 hung_kind_0=3\n")
        #expect(CrashKeySlots.writeRecord(wordsAt: 0, into: buffer) == "crash_keys\n".utf8.count, "no block: an empty record")
    }

    @Test func aScopedKeyPutsTheOuterValueBack() {
        let keys = CrashKeySlots()
        keys.withKey(.actionID, 1) {
            keys.withKey(.actionID, 2) { #expect(keys.value(.actionID) == 2) }
            #expect(keys.value(.actionID) == 1, "a nested run leaves the outer run's id")
        }
        #expect(keys.value(.actionID) == 0)
    }

    @Test func theHungThreadTableNamesEachThreadOnceAndHoldsAtMostItsCapacity() {
        let keys = CrashKeySlots()
        for port in 1...UInt32(CrashKeySlots.hungThreadCapacity) {
            #expect(keys.noteHung(CrashKeySlots.HungThread(port: port, kind: 3)))
        }
        #expect(keys.noteHung(CrashKeySlots.HungThread(port: 2, kind: 5)), "a named thread is updated in place")
        #expect(!keys.noteHung(CrashKeySlots.HungThread(port: 99, kind: 3)), "a ninth hung thread is not named")
        #expect(!keys.noteHung(CrashKeySlots.HungThread(port: 0, kind: 3)))
        #expect(keys.snapshot().hungThreadCount == CrashKeySlots.hungThreadCapacity)
        #expect(keys.snapshot().hungThread(at: 1)?.kind == 5)
        keys.clearHung(port: 2)
        #expect(keys.snapshot().hungThreadCount == CrashKeySlots.hungThreadCapacity - 1)
        #expect(keys.noteHung(CrashKeySlots.HungThread(port: 99, kind: 3)), "a cleared entry is reused")
    }

    @Test func tagsHoldNumbersAndCatalogNamesOnly() {
        let keys = CrashKeySlots()
        keys.set(.actionID, CrashKeySlots.stableKey("workspace.new"))
        keys.set(.paneKind, CrashKeySlots.PaneKind.browser.rawValue)
        keys.set(.cefState, CrashKeySlots.CEFState.inPump.rawValue)
        keys.noteHung(CrashKeySlots.HungThread(port: 4242, kind: 3))
        let tags = keys.snapshot().tags
        #expect(tags["crash_key.action_id"] == String(CrashKeySlots.stableKey("workspace.new"), radix: 16))
        #expect(tags["crash_key.pane_kind"] == "browser")
        #expect(tags["crash_key.cef_state"] == "in_pump")
        #expect(tags["crash_key.hung_threads"] == "1")
        #expect(tags["crash_key.hung_thread_kinds"] == "lane")
        #expect(tags["crash_key.daemon_epoch"] == nil, "a key at 0 is left out")
        #expect(!tags.values.contains { $0.contains("4242") }, "a thread port never leaves the process")
    }

    @Test func theStableKeyMatchesTheRustCrate() {
        // cmux-tui/crates/cmux-panic-log/src/crash_keys.rs `stable_key`: FNV-1a 64, never 0.
        #expect(CrashKeySlots.stableKey("") == 0xCBF2_9CE4_8422_2325)
        #expect(CrashKeySlots.stableKey("a") == 0xAF63_DC4C_8601_EC8C)
    }
}
