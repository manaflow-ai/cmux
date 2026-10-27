public import CmuxNextWakeups
import CmuxNextCompat
import Darwin

/// The crash keys of one moment (``CmuxNextWakeups/CrashKeySlots``) as the crash path writes them and a
/// report reads them (plans/cmux-next/chrome-parity/p10-stability.md section 3B, task 207).
///
/// Chrome reads its crash keys out of the dead process (Crashpad, components/crash/core/common/crash_key.h);
/// cmux's crash path writes them itself, as one line into the run marker folder's `run.crashkeys`
/// (``CrashReporter/recordCrashKeys()``), after the crash's own record: the fatal-signal handler after
/// `run.signal`, an uncaught exception after `run.exception`, the crash gate's frozen and suspended crashes
/// after their deadline is armed. Writing loads each word straight from the slots, allocates nothing, takes no
/// lock and makes one `write(2)` from a buffer allocated at launch, so it is async-signal-safe.
///
/// The line format is ``CmuxNextWakeups/CrashKeySlots/writeRecord(into:word:)``'s. Reading a line back
/// (``init(record:)``) keeps only the names it writes and only decimal values, so whatever else a damaged or
/// planted file holds never reaches a report: the keys are scrubbed. The next launch puts them into the
/// previous run's app crash report and its GitHub issue text (`CrashRecoveryService` in CmuxNextApp).
public struct CrashKeys: Sendable, Equatable {
    /// The keys' values.
    public var snapshot: CrashKeySlots.Snapshot

    /// The keys of `snapshot`.
    public init(_ snapshot: CrashKeySlots.Snapshot) {
        self.snapshot = snapshot
    }

    /// The longest line ``write(into:)`` writes, its newline included.
    public static var maxRecordBytes: Int { CrashKeySlots.maxRecordBytes }

    /// Writes the record line into `buffer` (at least ``maxRecordBytes`` bytes for a whole line; a shorter buffer
    /// gets a cut line). No allocation, no lock.
    ///
    /// - Returns: The number of bytes written.
    public func write(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        // SAFETY: writeRecord writes at most buffer.count bytes into the caller's buffer (a shorter one gets a cut line).
        unsafe snapshot.writeRecord(into: buffer)
    }

    /// The keys of a line ``write(into:)`` wrote; nil when `record` is not one. Unknown names, values that are not
    /// decimal numbers and hung-thread kinds past the capacity are dropped.
    public init?(record: String) {
        var words = record.split(whereSeparator: { $0 == " " || $0 == "\n" }).makeIterator()
        guard words.next() == "crash_keys" else { return nil }
        var snapshot = CrashKeySlots.Snapshot()
        var kinds = 0
        while let word = words.next() {
            let parts = word.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[1].utf8.count <= 20, parts[1].utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let value = UInt64(parts[1]) else { continue }
            switch parts[0] {
            case "action_id": snapshot.actionID = value
            case "pane_kind": snapshot.paneKind = value
            case "cef_state": snapshot.cefState = value
            case "daemon_epoch": snapshot.daemonEpoch = value
            default:
                guard parts[0].hasPrefix("hung_kind_"), kinds < CrashKeySlots.hungThreadCapacity,
                      let kind = UInt8(exactly: value) else { continue }
                // The record has kinds, not ports: entry n gets port n + 1, so it reads as set.
                snapshot.setHungThread(CrashKeySlots.HungThread(port: UInt32(kinds + 1), kind: kind), at: kinds)
                kinds += 1
            }
        }
        self.init(snapshot)
    }

    /// The keys as a report's tags (``CmuxNextWakeups/CrashKeySlots/Snapshot/tags``).
    public var tags: [String: String] { snapshot.tags }

    /// The tags as one `crash_key.<name>=<value>` line sorted by name, `none` when no key is set (a log line,
    /// an issue's text).
    public var tagLine: String {
        let tags = tags
        return tags.isEmpty ? "none" : tags.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}

// MARK: - The crash path

extension CrashReporter {
    /// Allocates the crash path's block (``CrashKeysRecordBlock``) and publishes its address. Call once at launch,
    /// on the main thread, before any crash handler that reads it is installed: `AppRunMarker` calls it first,
    /// before the uncaught-exception handler, the crash deadline and the fatal-signal handlers, whether or not
    /// its files open. Later calls do nothing.
    public static func prepareCrashKeysBlock() {
        CrashKeysRecordBlock.prepare()
    }

    /// Whether ``prepareCrashKeysBlock()`` has run in this process (tests).
    package static var crashKeysBlockIsPrepared: Bool { CrashKeysRecordBlock.current != nil }

    /// Hands the crash path the app's crash keys (the composition root's ``CrashKeySlots``). The slots are kept
    /// for the process's life: the crash path reads them by address. Call once at launch, on the main thread,
    /// after ``prepareCrashKeysBlock()``; before it, and on later calls, does nothing.
    public static func attachCrashKeys(_ slots: CrashKeySlots) {
        guard let block = CrashKeysRecordBlock.current, block.slotsWord.load(ordering: .acquiring) == 0 else { return }
        // SAFETY: one +1 retain that is never released, so the slots' words stay at their address for the process's
        // life; the crash path holds that address, not a reference.
        _ = unsafe Unmanaged.passRetained(slots) // released never: the crash path holds the address, not a reference
        // One dry write at launch: every function and type the crash path's write uses has run once, so no
        // first-use work (a symbol bind, type metadata) is left for a signal handler.
        // SAFETY: the slots' words live for the process (retained above); block.line is the block's own
        // maxRecordBytes-byte line, which writeRecord does not write past.
        _ = unsafe CrashKeySlots.writeRecord(wordsAt: slots.wordsAddress, into: block.line)
        block.slotsWord.store(UInt64(slots.wordsAddress), ordering: .releasing)
    }

    /// Hands the crash path this run's open, empty `run.crashkeys` file (the run marker's folder): sets the
    /// block's descriptor word only. Call once at launch, on the main thread, after ``prepareCrashKeysBlock()``;
    /// before it, and on later calls, does nothing.
    public static func prepareCrashKeysRecord(descriptor: Int32) {
        guard descriptor >= 0, let block = CrashKeysRecordBlock.current else { return }
        _ = block.descriptorWord.compareExchange(expected: 0, desired: UInt64(descriptor) + 1, ordering: .acquiringAndReleasing)
    }

    /// Writes this run's crash keys into `run.crashkeys` (``CrashKeys``), the first time a crash path calls it.
    /// Call after the crash's own record (`run.signal`, `run.exception`), so a fault in here never costs that
    /// record. Async-signal-safe: each word loaded straight from the slots, no allocation, no lock, one `write(2)`
    /// from the buffer allocated at launch. Does nothing before both halves are attached.
    public static func recordCrashKeys() {
        guard let block = CrashKeysRecordBlock.current else { return }
        let slots = UInt(truncatingIfNeeded: block.slotsWord.load(ordering: .acquiring))
        guard slots != 0 else { return }
        // Only the first crash path writes (an abort may follow a fatal signal's handler), on whichever thread.
        let taken = block.descriptorWord.exchange(0, ordering: .acquiringAndReleasing)
        guard taken != 0 else { return }
        // SAFETY: `slots` is the address attachCrashKeys published, of words retained for the process's life;
        // block.line is the block's maxRecordBytes-byte line, which writeRecord does not write past.
        let count = unsafe CrashKeySlots.writeRecord(wordsAt: slots, into: block.line)
        // concurrency-allow: async-signal-safe crash path (the process is ending), which can run no seam; one write
        // of at most 512 bytes to this run's local file.
        // blocking-allow: a fatal-signal handler can call no seam (blockingCall records and may allocate).
        // SAFETY: write reads `count` bytes, at most the line's maxRecordBytes that writeRecord just filled.
        _ = unsafe Darwin.write(Int32(truncatingIfNeeded: taken - 1), block.line.baseAddress, count)
    }
}

/// The crash path's state, in one block allocated at launch and kept for the process's life: the slots'
/// address, this run's `run.crashkeys` descriptor (plus 1; 0 is none or already written) and the record line's
/// buffer. Chrome keeps crash keys in static storage for the same reason: the crash path runs no allocator.
// SAFETY (the block): `base` is the start of ``wordCount`` UInt64 words that prepare() allocated, bound to UInt64
// and zeroed, and that are never freed; the two words and the line below lie inside them.
@safe private struct CrashKeysRecordBlock {
    let base: UnsafeMutableRawPointer

    /// Two words, then the line (a whole number of words: ``CrashKeys/maxRecordBytes`` is 512).
    static var wordCount: Int { 2 + CrashKeys.maxRecordBytes / 8 }

    // SAFETY: as above (the block): word 0, 8-byte aligned.
    var slotsWord: AtomicPointerSlot { unsafe AtomicPointerSlot(base.assumingMemoryBound(to: UInt64.self)) }
    // SAFETY: as above (the block): word 1.
    var descriptorWord: AtomicPointerSlot { unsafe AtomicPointerSlot(base.assumingMemoryBound(to: UInt64.self) + 1) }
    // SAFETY: as above (the block): the line is the maxRecordBytes bytes after the two words, the block's end.
    var line: UnsafeMutableRawBufferPointer { unsafe UnsafeMutableRawBufferPointer(start: base + 16, count: CrashKeys.maxRecordBytes) }

    /// The block, nil before launch made it. Async-signal-safe (no generic `map`): the acquiring fence after a
    /// non-zero address pairs with ``prepare()``'s releasing fence, so the block's zeroed words are seen.
    static var current: CrashKeysRecordBlock? {
        // SAFETY: a non-zero word is the address prepare() published, of a block that is never freed (see above).
        guard let base = unsafe UnsafeMutableRawPointer(bitPattern: crashKeysRecordBlock) else { return nil }
        atomicFence(ordering: .acquiring)
        // SAFETY: as above.
        return unsafe CrashKeysRecordBlock(base: base)
    }

    /// Makes the block the first time (launch, main thread): zeroes its words, then publishes its address after
    /// a releasing fence, so a crash handler on another thread that loads the address sees the zeroes, never the
    /// allocator's old bytes.
    static func prepare() {
        guard current == nil else { return }
        // SAFETY: allocates the wordCount words of the block, then zeroes exactly those words; the block is never freed.
        let words = unsafe UnsafeMutablePointer<UInt64>.allocate(capacity: wordCount)
        unsafe words.initialize(repeating: 0, count: wordCount)
        atomicFence(ordering: .releasing)
        // SAFETY: publishes the address only, once, on the main thread at launch; readers rebuild the pointer from it
        // (``current``). See the declaration for its threads.
        unsafe crashKeysRecordBlock = UInt(bitPattern: words)
    }
}

// The block's address: 0 until `AppRunMarker.start()` calls `CrashReporter.prepareCrashKeysBlock()`, its first
// step, on the main thread, before it installs the uncaught-exception handler, the crash deadline and the
// fatal-signal handlers that read it; never changed after. A constant initial value, so no lazy initialization
// runs in a signal handler; one aligned word, so a load sees 0 or the whole address. The store follows a releasing
// fence and every load is followed by an acquiring one (CrashKeysRecordBlock.prepare() and .current).
// Threads: stored on the main thread at launch; read by fatal-signal handlers on whichever thread faulted and by the
// uncaught-exception handler. No lock: a signal handler that waits for a lock the interrupted thread holds never
// returns, and os_unfair_lock is not async-signal-safe.
// crash-allow: async-signal-safe global, stored once on the main thread, read by signal handlers (why no lock: above).
nonisolated(unsafe) private var crashKeysRecordBlock: UInt = 0
