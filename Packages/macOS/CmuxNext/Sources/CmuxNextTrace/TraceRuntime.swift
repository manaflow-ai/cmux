// Public: the inlined category check reads the Compat `Atomic` from other modules, and its
// `UInt64: AtomicValue` conformance comes from swift-atomics, so inlinable code needs that import too.
public import Atomics
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
/// The write methods publish into the ring its owner attaches (``attach(_:)``): the black box, which
/// `TraceBlackBox` makes and attaches at launch (task 005), so the runtime holds it from then on. Catalog
/// names go by id and interned names by their id in the active ring (tasks 003 and 004). The category
/// defaults are ``TraceCategories`` (task 005). The API is frozen (task 000); recording (020) and crash keys
/// (078) are still stubs.
///
/// ```swift
/// TraceRuntime.shared.write(name: 46, categoryBit: 10, phase: .instant)
/// ```
public final class TraceRuntime: Sendable {
    /// The app's runtime: every Swift trace point, hang-watch scope and histogram of this process.
    // singleton-allow: Chrome's TraceLog: trace points run in every module and thread with no injection path;
    // lint:allow singleton: the one reviewed TraceRuntime exception in plans/cmux-next/arch-ratchet.json (2026-10-25).
    public static let shared = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: nil, routesBlockingCalls: true)

    /// The process kind this runtime records (the ring header's `role`).
    public let role: Role
    /// The hang-watch slots of this process's watched threads and lanes.
    public let hangWatch: HangWatch
    /// One bit per category (`SignpostCategory.traceBit`, ``TraceCategories``); a trace point records only
    /// while its bit is set. Usable from inline code so a trace point in another module inlines the check.
    @usableFromInline let categoryFlags = Atomic<UInt64>(0)
    /// The categories last asked for (launch defaults, `trace.start`, `trace.stop`), before the keystroke-timing
    /// gate; ``categoryFlags`` is this word without ``TraceCategories/keyTiming`` while the gate is closed.
    let requestedFlags = Atomic<UInt64>(0)
    /// The ``KeyTimingHold`` bits that hold the keystroke-timing gate closed; the gate is open at 0.
    let keyTimingHoldBits = Atomic<UInt64>(0)
    /// The records the `write` methods let through their category gate while no ring is attached, so a
    /// test's runtime with no ring can see the gate.
    let stubRecordCount = Atomic<UInt64>(0)
    /// The clock of every record's `t_ns` (plans/cmux-next/trace.md "Release trace ring v1").
    let clock: TraceClock
    /// A test's sink that sees each catalog record this runtime writes while no ring is attached, with the
    /// fields the ring would hold. nil outside tests.
    let stubRecorder: (@Sendable (StubRecord) -> Void)?

    /// The address of the ``TraceRing`` the write methods publish to (an `Unmanaged` reference retained
    /// once by ``attach(_:)`` and never released: a ring lives as long as its process), 0 until its owner
    /// attaches it.
    let ringAddress = Atomic<UInt64>(0)
    /// The last scope ``nextAsyncScope()`` handed out.
    let asyncScopes = Atomic<UInt64>(0)
    /// The address of this runtime's ``CmuxNextCompat/BlockingTraceSink`` (an `Unmanaged` reference retained once
    /// and never released) when it routes the process's checked blocking calls (``shared`` does), else 0. Set
    /// once, in `init`, before any other thread sees the runtime.
    let blockingSinkAddress = Atomic<UInt64>(0)
    /// The address of the histogram store ``attachMetrics(_:)`` attached (retained once and never released, as
    /// the ring), 0 until its owner attaches one.
    let metricsAddress = Atomic<UInt64>(0)

    /// A runtime for a process of kind `role`, with every category off and no ring yet.
    ///
    /// - Parameters:
    ///   - role: The process kind.
    ///   - clock: The clock that stamps records (tests inject one).
    public convenience init(role: Role, clock: TraceClock = TraceClock()) {
        self.init(role: role, clock: clock, stubRecorder: nil)
    }

    /// A runtime whose records take their times from `clock` and, while no ring is attached, go to
    /// `stubRecorder` too (tests). With `routesBlockingCalls`, the process's checked blocking calls write their
    /// `task.blocking_call` intervals into this runtime while its `task` category records
    /// (``CmuxNextCompat/BlockingTraceHook``): ``shared``, and a test that checks those intervals.
    init(role: Role, clock: TraceClock, stubRecorder: (@Sendable (StubRecord) -> Void)?, routesBlockingCalls: Bool = false) {
        self.role = role
        self.clock = clock
        self.stubRecorder = stubRecorder
        hangWatch = HangWatch()
        if routesBlockingCalls { installBlockingCallSink() }
    }

    // MARK: ring

    /// Points the write methods at `ring`, the process's ring (heap first, then its file, as the ring
    /// itself switches). Its owner (`TraceBlackBox`, task 005) attaches it once, right after making it;
    /// until then a record that passes its category gate goes nowhere. Chrome's `TraceLog` owns its one
    /// buffer the same way (base/trace_event/trace_log.h).
    ///
    /// - Returns: false when a ring was attached already (the first one stays).
    @discardableResult
    public func attach(_ ring: TraceRing) -> Bool {
        let retained = Unmanaged.passRetained(ring)
        let address = UInt64(UInt(bitPattern: retained.toOpaque()))
        guard ringAddress.compareExchange(expected: 0, desired: address, ordering: .sequentiallyConsistent).exchanged else {
            retained.release()
            return false
        }
        // Read after the ring is visible: a publish that saw no ring stored its flags before this load.
        ring.mirrorCategories(categoryFlags.load(ordering: .sequentiallyConsistent))
        return true
    }

    /// The attached ring (the black box), nil until ``attach(_:)``.
    public var ring: TraceRing? {
        attachedRing?.takeUnretainedValue()
    }

    /// The attached ring, read with no reference-count traffic on the write path.
    @inline(__always)
    private var attachedRing: Unmanaged<TraceRing>? {
        UnsafeRawPointer(bitPattern: UInt(ringAddress.load(ordering: .acquiring))).map { Unmanaged.fromOpaque($0) }
    }

    // MARK: metrics

    /// Gives this runtime its histogram store, CmuxNextMetrics' `MetricsStore` (the only caller), which every
    /// `Metrics(runtime:)` of the process then records into. Chrome keeps one `GlobalHistogramAllocator` per
    /// process beside its `TraceLog` the same way (base/metrics/persistent_histogram_allocator.h).
    ///
    /// - Returns: false when a store was attached already (the first one stays).
    @discardableResult
    package func attachMetrics<Store: AnyObject & Sendable>(_ store: Store) -> Bool {
        let retained = Unmanaged.passRetained(store)
        let address = UInt64(UInt(bitPattern: retained.toOpaque()))
        guard metricsAddress.compareExchange(expected: 0, desired: address, ordering: .acquiringAndReleasing).exchanged else {
            retained.release()
            return false
        }
        return true
    }

    /// The store ``attachMetrics(_:)`` attached, unretained (it lives as long as the process), nil until then.
    package var attachedMetrics: Unmanaged<AnyObject>? {
        UnsafeRawPointer(bitPattern: UInt(metricsAddress.load(ordering: .acquiring))).map { Unmanaged.fromOpaque($0) }
    }

    // MARK: categories

    /// The category flags: bit `n` on means category bit `n` records.
    @inlinable
    public var categoryMask: UInt64 { categoryFlags.load(ordering: .relaxed) }

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

    /// Publishes one catalog record into the attached ring, or to the test's stub when no ring is attached.
    private func publish(name: UInt16, categoryBit: UInt8, phase: Phase, flags: RecordFlags, arg0: UInt64, arg1: UInt64) {
        let timestamp = clock.nowNanos()
        guard let ring = attachedRing else {
            stubRecordCount.add(1, ordering: .relaxed) // No ring attached (a test's runtime): count what passed the gate.
            stubRecorder?(StubRecord(tNanos: timestamp, name: name, categoryBit: categoryBit, phase: phase,
                                     flags: flags, arg0: arg0, arg1: arg1))
            return
        }
        ring._withUnsafeGuaranteedRef {
            $0.write(name: name, phase: phase.recordPhase, flags: flags.rawValue, timestamp: timestamp, arg0: arg0, arg1: arg1)
        }
    }

    /// Writes one record under a name outside the catalog (a task's post site, an acpmux callsite) when
    /// its category is on. The name has one id per ring, claimed at its first record there
    /// (trace.md "Name table": interned ids follow the ring's catalog and category entries, from the
    /// ring's `name_cursor`); past the ring's `name_capacity` the record has no name.
    ///
    /// - Returns: Whether the record passed its category gate. A begin's caller keeps it and ends a written begin
    ///   with ``writeEnd(_:phase:flags:arg0:arg1:)``.
    @discardableResult
    public func write(_ name: InternedName, phase: Phase, flags: RecordFlags = [], arg0: UInt64 = 0, arg1: UInt64 = 0) -> Bool {
        guard isEnabled(categoryBit: name.categoryBit) else { return false }
        publish(name, phase: phase, flags: flags, arg0: arg0, arg1: arg1)
        return true
    }

    /// Writes the end (E or AE) of a begin that ``write(_:phase:flags:arg0:arg1:)`` wrote, without reading the
    /// category flags, as ``writeEnd(name:categoryBit:phase:flags:arg0:arg1:)`` does for a catalog name.
    public func writeEnd(_ name: InternedName, phase: Phase, flags: RecordFlags = [], arg0: UInt64 = 0, arg1: UInt64 = 0) {
        publish(name, phase: phase, flags: flags, arg0: arg0, arg1: arg1)
    }

    /// Publishes one record under an interned name into the attached ring; with no ring (a test's runtime) it
    /// only counts.
    private func publish(_ name: InternedName, phase: Phase, flags: RecordFlags, arg0: UInt64, arg1: UInt64) {
        guard let ring = attachedRing else {
            stubRecordCount.add(1, ordering: .relaxed) // No ring attached (a test's runtime): count what passed the gate.
            return
        }
        let timestamp = clock.nowNanos()
        ring._withUnsafeGuaranteedRef {
            $0.write(name, phase: phase.recordPhase, flags: flags.rawValue, timestamp: timestamp, arg0: arg0, arg1: arg1)
        }
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

    // MARK: async ids

    /// A number no earlier call on this runtime returned, from 1: the scope an owner of async ids that restart at
    /// 1 (a daemon connection's request ids) puts in their high bits, so two owners' slices never pair, even when
    /// one owner's last slice ends after the next one opens. Chrome mints process-unique ids from one sequence
    /// the same way (base/atomic_sequence_num.h).
    public func nextAsyncScope() -> UInt64 {
        asyncScopes.add(1, ordering: .relaxed).newValue
    }

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
        /// acpmux's `__agent-host`, one per harness.
        case agentHost = 8
        /// `cmux-app-host`, one sandboxed VM per app.
        case appHost = 9
        /// `cmux-browser-host serve`, the agent browser runtime.
        case browserHost = 10
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
    }

    /// A trace point named at run time, outside the catalog: a `static let` at its site. It keeps its
    /// id for each of the process's three ring slots (heap, black box, recording) in one atomic word per
    /// slot: the id in bits 0-15 and the tag of the ring that gave it above them, 0 until it is interned
    /// there (trace.md "Name table"; Rust's `InternedName`). The tag makes an id serve only its own ring,
    /// so a second ring in one slot (a test's runtime) interns the name again instead of using another
    /// ring's id. `StaticString` only, so no person's text can become a name.
    public final class InternedName: Sendable {
        /// The name's text (at most 55 UTF-8 bytes in a ring entry).
        public let text: StaticString
        /// The category bit that gates its records (`SignpostCategory.traceBit`).
        public let categoryBit: UInt8
        /// Its tagged id in the heap ring (slot 0).
        let heapID = Atomic<UInt64>(0)
        /// Its tagged id in the black-box file (slot 1).
        let fileID = Atomic<UInt64>(0)
        /// Its tagged id in the recording ring (slot 2).
        let recordingID = Atomic<UInt64>(0)

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
        /// Whether per-key records and key flows are on (off by default; never while secure input is on:
        /// ``TraceRuntime/isKeyTimingSuppressed``).
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

extension TraceRuntime.Phase {
    /// The same phase as the ring's record type names it (one byte value in both).
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
