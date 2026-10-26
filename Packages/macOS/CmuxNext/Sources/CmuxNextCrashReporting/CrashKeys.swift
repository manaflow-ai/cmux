public import CmuxNextWakeups
import CmuxNextCompat
import Darwin

/// The crash keys of one moment (``CmuxNextWakeups/CrashKeySlots``) as the crash path writes them and a
/// report reads them (plans/cmux-next/chrome-parity/p10-stability.md section 3B, task 207).
///
/// Chrome reads its crash keys out of the dead process (Crashpad, components/crash/core/common/crash_key.h);
/// cmux's crash path writes them itself, as one line into the run marker folder's `run.crashkeys`, from
/// ``CrashReporter/beginCrashDeadline()``: every crash path (a fatal signal, an uncaught exception, the crash
/// gate's frozen and suspended crashes) passes there. Writing allocates nothing, takes no lock and makes one
/// `write(2)` from a buffer allocated at launch, so it is async-signal-safe.
///
/// The line is `crash_keys` and then `name=value` words, every value a decimal number:
/// `crash_keys action_id=1234 pane_kind=1 cef_state=2 daemon_epoch=3 hung_threads=1 hung_kind_0=3`. Keys at 0
/// are left out, and hung threads go by kind only (a thread port means nothing after the process ended).
/// Reading a line back (``init(record:)``) keeps only the names this type writes and only decimal values, so
/// whatever else a damaged or planted file holds never reaches a report: the keys are scrubbed.
public struct CrashKeys: Sendable, Equatable {
    /// The keys' values.
    public var snapshot: CrashKeySlots.Snapshot

    /// The keys of `snapshot`.
    public init(_ snapshot: CrashKeySlots.Snapshot) {
        self.snapshot = snapshot
    }

    /// The longest line ``write(into:)`` writes, its newline included (the longest possible line is under 300
    /// bytes).
    public static var maxRecordBytes: Int { 512 }

    /// Writes the record line into `buffer` (at least ``maxRecordBytes`` bytes for a whole line; a shorter buffer
    /// gets a cut line). No allocation, no lock: async-signal-safe.
    ///
    /// - Returns: The number of bytes written.
    public func write(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        var line = RecordWriter(buffer)
        line.append("crash_keys")
        line.field(CrashKeySlots.Key.actionID.name, snapshot.actionID)
        line.field(CrashKeySlots.Key.paneKind.name, snapshot.paneKind)
        line.field(CrashKeySlots.Key.cefState.name, snapshot.cefState)
        line.field(CrashKeySlots.Key.daemonEpoch.name, snapshot.daemonEpoch)
        line.field("hung_threads", UInt64(snapshot.hungThreadCount))
        var named: UInt64 = 0
        for index in 0..<CrashKeySlots.hungThreadCapacity {
            guard let thread = snapshot.hungThread(at: index) else { continue }
            line.append(" hung_kind_")
            line.decimal(named)
            line.append("=")
            line.decimal(UInt64(thread.kind))
            named += 1
        }
        line.append("\n")
        return line.count
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
                guard parts[0].hasPrefix("hung_kind_"), kinds < CrashKeySlots.hungThreadCapacity, value <= UInt64(UInt8.max),
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
}

/// Appends ASCII to a caller's buffer with no allocation; stops at the buffer's end.
private struct RecordWriter {
    let buffer: UnsafeMutableRawBufferPointer
    private(set) var count = 0

    init(_ buffer: UnsafeMutableRawBufferPointer) {
        self.buffer = buffer
    }

    mutating func byte(_ value: UInt8) {
        guard count < buffer.count else { return }
        buffer[count] = value
        count += 1
    }

    mutating func append(_ text: StaticString) {
        text.withUTF8Buffer { for value in $0 { byte(value) } }
    }

    /// ` name=value`, left out when `value` is 0.
    mutating func field(_ name: StaticString, _ value: UInt64) {
        guard value != 0 else { return }
        byte(0x20)
        append(name)
        byte(0x3D)
        decimal(value)
    }

    mutating func decimal(_ value: UInt64) {
        var divisor: UInt64 = 1
        while value / divisor >= 10 { divisor *= 10 }
        var rest = value
        while divisor > 0 {
            byte(0x30 + UInt8(truncatingIfNeeded: rest / divisor))
            rest %= divisor
            divisor /= 10
        }
    }
}

// MARK: - The crash path

extension CrashReporter {
    /// Hands the crash path the app's crash keys (the composition root's ``CrashKeySlots``). The slots are kept
    /// for the process's life: the crash path reads them by address. Call once at launch, on the main thread;
    /// later calls are ignored.
    public static func attachCrashKeys(_ slots: CrashKeySlots) {
        let block = CrashKeysRecordBlock.prepared()
        guard block.slotsWord.load(ordering: .acquiring) == 0 else { return }
        _ = Unmanaged.passRetained(slots) // released never: the crash path holds the address, not a reference
        block.slotsWord.store(UInt64(slots.wordsAddress), ordering: .releasing)
    }

    /// Hands the crash path this run's open, empty `run.crashkeys` file (the run marker's folder). Call once at
    /// launch, on the main thread, before the crash handlers are installed; later calls are ignored.
    public static func prepareCrashKeysRecord(descriptor: Int32) {
        guard descriptor >= 0 else { return }
        let block = CrashKeysRecordBlock.prepared()
        _ = block.descriptorWord.compareExchange(expected: 0, desired: UInt64(descriptor) + 1, ordering: .acquiringAndReleasing)
    }

    /// Writes this run's crash keys into `run.crashkeys` (``CrashKeys``), the first time a crash path calls it.
    /// Async-signal-safe: no allocation, no lock, one `write(2)` from the buffer allocated at launch. Does nothing
    /// before both halves are attached.
    static func writeCrashKeysRecord() {
        guard let block = CrashKeysRecordBlock.current else { return }
        let slots = UInt(truncatingIfNeeded: block.slotsWord.load(ordering: .acquiring))
        guard slots != 0 else { return }
        // Only the first crash path writes (an abort may follow a fatal signal's handler), on whichever thread.
        let taken = block.descriptorWord.exchange(0, ordering: .acquiringAndReleasing)
        guard taken != 0 else { return }
        let count = CrashKeys(CrashKeySlots.read(wordsAt: slots)).write(into: block.line)
        // concurrency-allow: async-signal-safe crash path (the process is ending), which can run no seam; one write
        // of at most 512 bytes to this run's local file.
        _ = Darwin.write(Int32(truncatingIfNeeded: taken - 1), block.line.baseAddress, count)
    }
}

/// The crash path's state, in one block allocated at launch and kept for the process's life: the slots'
/// address, this run's `run.crashkeys` descriptor (plus 1; 0 is none or already written) and the record line's
/// buffer. Chrome keeps crash keys in static storage for the same reason: the crash path runs no allocator.
private struct CrashKeysRecordBlock {
    let base: UnsafeMutableRawPointer

    /// Two words, then the line (a whole number of words: ``CrashKeys/maxRecordBytes`` is 512).
    static var wordCount: Int { 2 + CrashKeys.maxRecordBytes / 8 }

    var slotsWord: AtomicPointerSlot { AtomicPointerSlot(base.assumingMemoryBound(to: UInt64.self)) }
    var descriptorWord: AtomicPointerSlot { AtomicPointerSlot(base.assumingMemoryBound(to: UInt64.self) + 1) }
    var line: UnsafeMutableRawBufferPointer { UnsafeMutableRawBufferPointer(start: base + 16, count: CrashKeys.maxRecordBytes) }

    /// The block, nil before launch made it. Async-signal-safe.
    static var current: CrashKeysRecordBlock? {
        UnsafeMutableRawPointer(bitPattern: crashKeysRecordBlock).map(CrashKeysRecordBlock.init(base:))
    }

    /// The block, made the first time (launch, main thread).
    static func prepared() -> CrashKeysRecordBlock {
        if let current { return current }
        let words = UnsafeMutablePointer<UInt64>.allocate(capacity: wordCount)
        words.initialize(repeating: 0, count: wordCount)
        crashKeysRecordBlock = UInt(bitPattern: words)
        return CrashKeysRecordBlock(base: UnsafeMutableRawPointer(words))
    }
}

// The block's address: set once at launch on the main thread, before the crash handlers that read it are
// installed, and never changed; a constant initial value, so no lazy initialization runs in a signal handler.
// crash-allow: written once at launch before any reader, read-only after (signal-handler state).
nonisolated(unsafe) private var crashKeysRecordBlock: UInt = 0
