// Public: the inlined category check reads the Compat `Atomic` from other modules.
public import CmuxNextCompat

/// The process's one trace runtime: the category flags every trace point reads, and (as the later
/// p09-observability tasks land) the black-box and recording rings, the name and thread tables, the
/// crash-key page and the hang-watch slots (plans/cmux-next/chrome-parity/p09-observability.md
/// section 3A).
///
/// Chrome keeps the same state in one process-wide object, `base::trace_event::TraceLog`
/// (base/trace_event/trace_log.h), next to `base::GlobalHistogramAllocator`
/// (base/metrics/persistent_histogram_allocator.h) and `base::HangWatcher`
/// (base/threading/hang_watcher.h). A trace point runs in every module and on every thread, often with
/// no object to inject through (a renderer callback, a C hook, a `deinit`), so ``shared`` is the
/// single reviewed exception to the no-singleton rule (plans/cmux-next/arch-ratchet.json, 2026-10-25).
/// Code that can take an injected runtime does (``init(role:)``; tests make their own).
///
/// The runtime owns the process's black-box ring: ``TraceBlackBox`` makes it at launch and installs it
/// here (``installBlackBox(_:)``), and from then on every ``write(name:categoryBit:phase:flags:arg0:arg1:)``
/// of the process lands in it, on the heap and then in its file. The category defaults are
/// ``TraceCategories`` (task 005). Still stubs: interned names (task 004), recording (020) and crash keys (078).
///
/// ```swift
/// TraceRuntime.shared.write(name: 46, categoryBit: 10, phase: .instant)
/// ```
public final class TraceRuntime: Sendable {
    /// The app's runtime: every Swift trace point, hang-watch scope and histogram of this process.
    // singleton-allow: Chrome's TraceLog: trace points run in every module and thread with no injection path;
    // lint:allow singleton: the one reviewed TraceRuntime exception in plans/cmux-next/arch-ratchet.json (2026-10-25).
    public static let shared = TraceRuntime(role: .app)

    /// The process kind this runtime records (the ring header's `role`).
    public let role: Role
    /// The hang-watch slots of this process's watched threads and lanes.
    public let hangWatch: HangWatch
    /// One bit per category (`SignpostCategory.traceBit`, ``TraceCategories``); a trace point records only
    /// while its bit is set. Usable from inline code so a trace point in another module inlines the check.
    @usableFromInline let categoryFlags = Atomic<UInt64>(0)
    /// The installed black-box ``TraceRing``: its retained address, 0 until ``installBlackBox(_:)``. Set once
    /// and never cleared, so a writer that loaded it may use it for the rest of the process.
    private let blackBoxCell = Atomic<UInt64>(0)
    /// A runtime with no ring (tests): the records the `write` methods let through their category gate, so
    /// tests can see the gate. Never touched once a ring is installed.
    let stubRecordCount = Atomic<UInt64>(0)
    /// The clock of every record's `t_ns` (plans/cmux-next/trace.md "Release trace ring v1").
    let clock: TraceClock
    /// Stub until task 003 adds the ring and its decoder: a test's sink that sees each record this runtime
    /// writes, with the fields the ring would hold. nil outside tests.
    let stubRecorder: (@Sendable (StubRecord) -> Void)?

    /// A runtime for a process of kind `role`, with every category off.
    public init(role: Role) {
        self.init(role: role, clock: TraceClock(), stubRecorder: nil)
    }

    /// A runtime whose records take their times from `clock` and go to `stubRecorder` too (tests).
    init(role: Role, clock: TraceClock, stubRecorder: (@Sendable (StubRecord) -> Void)?) {
        self.role = role
        self.clock = clock
        self.stubRecorder = stubRecorder
        hangWatch = HangWatch()
    }

    // MARK: categories

    /// The category flags: bit `n` on means category bit `n` records.
    @inlinable
    public var categoryMask: UInt64 { categoryFlags.load(ordering: .relaxed) }

    /// Replaces the category flags (launch defaults, `trace.start`, `trace.stop`, the secure-input gate) and
    /// mirrors them into the active ring's header `categories` (trace.md "Header").
    public func setCategoryMask(_ mask: UInt64) {
        categoryFlags.store(mask, ordering: .relaxed)
        withBlackBox { $0.mirrorCategories(mask) }
    }

    // MARK: black box

    /// Makes `ring` the process's black box: every later record goes to it. The first ring installed stays
    /// for the life of the process (a writer may hold it at any time), so a later call keeps the first.
    ///
    /// - Returns: The installed ring: `ring`, or the one an earlier call installed.
    @discardableResult
    public func installBlackBox(_ ring: TraceRing) -> TraceRing {
        let retained = Unmanaged.passRetained(ring)
        let bits = UInt64(UInt(bitPattern: retained.toOpaque()))
        let (installed, original) = blackBoxCell.compareExchange(expected: 0, desired: bits, ordering: .acquiringAndReleasing)
        if installed {
            ring.mirrorCategories(categoryMask)
            return ring
        }
        retained.release()
        return Self.ring(at: original)?.takeUnretainedValue() ?? ring
    }

    /// The installed black-box ring, nil before ``installBlackBox(_:)``.
    public var blackBox: TraceRing? {
        Self.ring(at: blackBoxCell.load(ordering: .acquiring))?.takeUnretainedValue()
    }

    /// Runs `body` with the installed ring and no reference count change (the cell's retain keeps the ring
    /// alive for the process), so trace points on many threads never write the ring object's count.
    @inline(__always)
    private func withBlackBox(_ body: (TraceRing) -> Void) {
        guard let ring = Self.ring(at: blackBoxCell.load(ordering: .acquiring)) else { return }
        ring._withUnsafeGuaranteedRef(body)
    }

    private static func ring(at bits: UInt64) -> Unmanaged<TraceRing>? {
        UnsafeRawPointer(bitPattern: UInt(bits)).map { Unmanaged<TraceRing>.fromOpaque($0) }
    }

    /// Whether category bit `bit` records: one relaxed load and one branch, the cost of a trace point
    /// that is off (Chrome's `category_group_enabled` read).
    @inlinable @inline(__always)
    public func isEnabled(categoryBit bit: UInt8) -> Bool {
        categoryFlags.load(ordering: .relaxed) & (1 << UInt64(bit & 63)) != 0
    }

    // MARK: records

    /// Writes one 32-byte ring record when the category is on. Never locks, allocates or calls the system.
    ///
    /// - Parameters:
    ///   - name: The catalog id (`SignpostName.rawValue`).
    ///   - categoryBit: The category's bit (`SignpostCategory.traceBit`).
    ///   - phase: What the record marks.
    ///   - flags: How to read the arguments.
    ///   - arg0: The first number (the name's doc comment says what it holds).
    ///   - arg1: The second number; the async id or track id when ``RecordFlags/asyncID`` is set.
    /// - Returns: Whether the record was written (its category was on). A begin's caller keeps it and ends a
    ///   written begin with ``writeEnd(name:categoryBit:phase:flags:arg0:arg1:)``.
    @discardableResult
    public func write(name: UInt16, categoryBit: UInt8, phase: Phase, flags: RecordFlags = [],
                      arg0: UInt64 = 0, arg1: UInt64 = 0) -> Bool {
        guard isEnabled(categoryBit: categoryBit) else { return false }
        publish(name: name, categoryBit: categoryBit, phase: phase, flags: flags, arg0: arg0, arg1: arg1)
        return true
    }

    /// Writes the end (E or AE) of a begin that ``write(name:categoryBit:phase:flags:arg0:arg1:)`` wrote, without
    /// reading the category flags: a recorded begin always gets its end, even when `trace.stop` or the
    /// secure-input gate turned its category off in between. Chrome's scoped trace event reads the category
    /// once, at the begin (base/trace_event/trace_event.h `INTERNAL_TRACE_EVENT_ADD_SCOPED`). Never call it for
    /// a begin whose write returned false.
    ///
    /// - Parameters: As ``write(name:categoryBit:phase:flags:arg0:arg1:)``.
    public func writeEnd(name: UInt16, categoryBit: UInt8, phase: Phase, flags: RecordFlags = [],
                         arg0: UInt64 = 0, arg1: UInt64 = 0) {
        publish(name: name, categoryBit: categoryBit, phase: phase, flags: flags, arg0: arg0, arg1: arg1)
    }

    /// Publishes the record into the black-box ring (one slot of this thread's chunk), or hands it to the
    /// stub counter and recorder when no ring is installed (tests).
    private func publish(name: UInt16, categoryBit: UInt8, phase: Phase, flags: RecordFlags, arg0: UInt64, arg1: UInt64) {
        if let ring = Self.ring(at: blackBoxCell.load(ordering: .acquiring)) {
            let timestamp = clock.nowNanos()
            ring._withUnsafeGuaranteedRef {
                $0.write(name: name, phase: phase.recordPhase, flags: flags.rawValue, timestamp: timestamp, arg0: arg0, arg1: arg1)
            }
            return
        }
        stubRecordCount.add(1, ordering: .relaxed)
        if let stubRecorder {
            stubRecorder(StubRecord(tNanos: clock.nowNanos(), name: name, categoryBit: categoryBit, phase: phase,
                                    flags: flags, arg0: arg0, arg1: arg1))
        }
    }

    /// Writes one record under a name outside the catalog (a task's post site, an acpmux callsite) when
    /// its category is on. The name has one id per ring, claimed at its first record there
    /// (trace.md "Name table": interned ids follow the ring's catalog and category entries, from the
    /// ring's `name_cursor`); past the ring's `name_capacity` the record has no name.
    public func write(_ name: InternedName, phase: Phase, flags: RecordFlags = [], arg0: UInt64 = 0, arg1: UInt64 = 0) {
        guard isEnabled(categoryBit: name.categoryBit) else { return }
        // Task 004 interns the name in the installed ring (`TraceRing.write(_:phase:...)`); until then a
        // ring-backed runtime drops it.
        guard blackBoxCell.load(ordering: .relaxed) == 0 else { return }
        stubRecordCount.add(1, ordering: .relaxed)
    }

    // MARK: recording

    /// Starts a recording: the larger ring and the requested categories, on top of the black box.
    ///
    /// - Returns: The recording's state after the call.
    @discardableResult
    public func startRecording(_ request: RecordingRequest) -> RecordingStatus {
        .idle // Task 020.
    }

    /// Stops the recording and restores the black-box categories.
    ///
    /// - Returns: The finished recording's ring path and size, or ``RecordingStatus/idle``.
    @discardableResult
    public func stopRecording() -> RecordingStatus {
        .idle // Task 020.
    }

    /// The current recording's state.
    public var recordingStatus: RecordingStatus { .idle }

    // MARK: crash keys

    /// Stores `value` in a crash-key slot (one relaxed store into the crash-key page).
    public func setCrashKey(_ slot: CrashKeySlot, _ value: UInt64) {
        // Task 078: the page.
    }

    /// The value a crash-key slot holds now (0 when never set).
    public func crashKey(_ slot: CrashKeySlot) -> UInt64 {
        0 // Task 078.
    }
}

extension TraceRuntime {
    /// The process kind of a ring: the header's `role` u16 at offset 20, the table in plans/cmux-next/trace.md
    /// ("Release trace ring v1", Header) that Rust's `cmux_trace::Role` and the C writer also follow. Fixed values.
    public enum Role: UInt16, Sendable, CaseIterable {
        /// The cmux app.
        case app = 1
        /// The cmux-tui daemon.
        case daemon = 2
        /// The PTY holder (`cmux-holder`).
        case holder = 3
        /// A terminal host (`cmux-tui-host`).
        case terminalHost = 4
        /// The acpmux daemon.
        case acpmux = 5
        /// The out-of-process Chromium host.
        case chromiumHost = 6
        /// The `cmux` CLI.
        case cli = 7
    }

    /// What a record marks: the record's phase byte, Chrome's ASCII `TRACE_EVENT_PHASE_*` codes
    /// (base/trace_event/common/trace_event_common.h), as in plans/cmux-next/trace.md "Release trace ring v1".
    public enum Phase: UInt8, Sendable, CaseIterable {
        /// `B`: a same-thread slice begins.
        case begin = 0x42
        /// `E`: the innermost open slice on this thread ends.
        case end = 0x45
        /// `I`: a point event.
        case instant = 0x49
        /// `b` (AB): an async slice begins (any thread; arg1 is its id, with ``RecordFlags/asyncID``).
        case asyncBegin = 0x62
        /// `e` (AE): the async slice with id arg1 ends, on any thread.
        case asyncEnd = 0x65
        /// `s`: a flow leaves this point (arg1 is the flow id).
        case flowOut = 0x73
        /// `f`: a flow arrives at this point (arg1 is the flow id).
        case flowIn = 0x66
        /// `C`: a counter value (arg0; arg1 a track id with ``RecordFlags/asyncID``).
        case counter = 0x43

        /// The same phase as the ring's record spells it (the same byte).
        @inline(__always)
        var recordPhase: TraceRecord.Phase {
            switch self {
            case .begin: .begin
            case .end: .end
            case .instant: .instant
            case .asyncBegin: .asyncBegin
            case .asyncEnd: .asyncEnd
            case .flowOut: .flowOut
            case .flowIn: .flowIn
            case .counter: .counter
            }
        }
    }

    /// A trace point named at run time, outside the catalog: a `static let` at its site. It keeps its
    /// id in each of the process's three rings (heap, black box, recording) in one atomic word, bits
    /// `16 * slot`, 0 until it is interned there (trace.md "Name table"; Rust's `InternedName`).
    /// `StaticString` only, so no person's text can become a name.
    public final class InternedName: Sendable {
        /// The name's text (at most 55 UTF-8 bytes in a ring entry).
        public let text: StaticString
        /// The category bit that gates its records (`SignpostCategory.traceBit`).
        public let categoryBit: UInt8
        /// Its id per ring slot (task 004 fills it).
        let ringIDs = Atomic<UInt64>(0)

        /// A name in category bit `categoryBit`.
        public init(_ text: StaticString, categoryBit: UInt8) {
            self.text = text
            self.categoryBit = categoryBit
        }
    }

    /// One record as the stub hands it to a test's recorder: the fields of the ring's 32-byte record
    /// (trace.md "Release trace ring v1") that the writer chooses. Task 003's decoder replaces it.
    struct StubRecord: Sendable, Equatable {
        /// `t_ns`: ``TraceClock`` nanoseconds at the write.
        var tNanos: UInt64
        /// The catalog id.
        var name: UInt16
        /// The category bit.
        var categoryBit: UInt8
        /// The phase.
        var phase: Phase
        /// How to read the arguments.
        var flags: RecordFlags
        /// The first number.
        var arg0: UInt64
        /// The second number.
        var arg1: UInt64
    }

    /// How to read a record's arguments (the record's flags byte).
    public struct RecordFlags: OptionSet, Sendable, Equatable {
        /// The byte.
        public let rawValue: UInt8
        /// Flags from the byte.
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// arg1 is an async id or a track id.
        public static let asyncID = RecordFlags(rawValue: 1 << 0)
        /// The timestamp is an estimate (`frame.present_estimate`), not a measurement.
        public static let estimated = RecordFlags(rawValue: 1 << 1)
    }

    /// What `trace.start` asks for. No path and no command: the runtime picks the files.
    public struct RecordingRequest: Sendable, Equatable {
        /// The categories to record (bits as ``categoryMask``), added to the black box's.
        public var categoryMask: UInt64
        /// The recording ring's size in records (capped by role).
        public var recordCapacity: Int
        /// Whether per-key records and key flows are on (off by default; never while secure input is on).
        public var keys: Bool

        /// A request.
        public init(categoryMask: UInt64, recordCapacity: Int, keys: Bool = false) {
            self.categoryMask = categoryMask
            self.recordCapacity = recordCapacity
            self.keys = keys
        }
    }

    /// A recording's state.
    public enum RecordingStatus: Sendable, Equatable {
        /// No recording runs (only the black box).
        case idle
        /// A recording runs into the ring at `ringPath`, `bytes` long.
        case recording(ringPath: String, bytes: Int)
        /// A recording ended; its ring is at `ringPath`.
        case stopped(ringPath: String, bytes: Int)
    }
}
