import CmuxNextCompat
import Darwin

/// The hang-watch slots of one process: each watched thread or lane registers once, then opens a
/// ``HangWatchScope`` around each unit of work, with a deadline (its budget). A monitor (the app's, on the
/// main-thread watchdog's thread: `HangMonitor` in CmuxNextControl) reports a scope in two tiers: a jank
/// when it is open past its budget, and a hang (a stack dump with crash keys) when it is still open
/// ``hangAfterBudget`` (2 s) later. Each tier is reported once per scope.
///
/// This is Chrome's `base::HangWatcher` model (base/threading/hang_watcher.h): `RegisterThread` per
/// thread type, `WatchHangsInScope` as a nesting RAII scope (default deadline 10 s), the deadline and
/// its flags packed in one atomic word (`HangWatchDeadline`), and `InvalidateActiveExpectations()` for
/// a wait the thread is allowed to make. cmux differs in two rules: its monitor parks while no scope
/// opens, so an idle process has no hang-watch wakeup (p09-observability.md section 3E), and a scope's
/// deadline is its jank budget, with the hang tier 2 s past it (Chrome measures jank apart from its 10 s
/// hang deadline; p10-stability.md section B).
///
/// Slots live in chunks of 64, 128 bytes each (one cache line, so two threads never share one), made on
/// first use: at most 4,096 registrations, the others are counted (``registrationOverflows``) and not
/// watched. Opening a scope is a clock read, one exchange of the packed deadline (a lane also stores the
/// running thread's port) and one load of the monitor's plan; closing is one compare-and-swap. Each edge
/// is one atomic read-modify-write, as the monitor's mark is, so neither loses a flag the monitor sets.
/// Neither takes a lock or makes a system call, except to wake the monitor (``scan(nowNanos:)`` says when).
///
/// ```swift
/// let lane = runtime.hangWatch.registerLane("terminal-output")
/// runtime.hangWatch.watch(lane, deadline: .seconds(1)) { feed(chunk) }
/// ```
public final class HangWatch: Sendable {
    /// The monitor's scan period while scopes open and close, and so the latency past a deadline at which
    /// a hang is seen. A shorter deadline is still watched, up to this much late.
    public let minimumDeadline: Duration
    public let periodNanos: UInt64 // ``minimumDeadline`` in nanoseconds (at least 1)
    /// How long a scope may stay open past its budget before the monitor reports it as a hang (a stack
    /// dump); before that it is a jank (a record with no stack).
    public let hangAfterBudget: Duration
    let hangAfterNanos: UInt64
    let clock: TraceClock
    /// The address of the chunk table: one word per chunk, the chunk's address or 0 (owned until deinit).
    private let chunks: UInt
    /// One past the highest slot index ever claimed: the monitor scans no further.
    let claimedEnd = Atomic<Int>(0)
    /// `CLOCK_UPTIME_RAW` nanoseconds of the monitor's next scan: 0 with no monitor (an open never wakes
    /// one), `.max` while it is parked or scanning (the next open wakes it).
    let plan = Atomic<UInt64>(0)
    /// The plan the monitor's last scan published; a different plan at the next scan means a scope moved it.
    let published = Atomic<UInt64>(0)
    /// An `Unmanaged` ``WakeBox`` retained by ``attachMonitor(wake:)`` (0: none), released at deinit.
    let wakeBox = Atomic<UInt64>(0)
    private let wakes = Atomic<UInt64>(0)
    private let overflows = Atomic<UInt64>(0)

    /// An empty slot table whose monitor scans every `minimumDeadline` while scopes open and close.
    ///
    /// - Parameters:
    ///   - minimumDeadline: The scan period while scopes open and close (100 ms).
    ///   - hangAfterBudget: How long past its budget a scope is a hang, not a jank (2 s).
    ///   - clock: The clock of every deadline (tests inject one).
    public init(minimumDeadline: Duration = .milliseconds(100), hangAfterBudget: Duration = .seconds(2),
                clock: TraceClock = TraceClock()) {
        self.minimumDeadline = minimumDeadline
        periodNanos = min(max(Self.nanos(minimumDeadline), 1), Self.deadlineMask)
        self.hangAfterBudget = hangAfterBudget
        hangAfterNanos = min(Self.nanos(hangAfterBudget), Self.deadlineMask)
        self.clock = clock
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Self.chunkLimit * 8, alignment: 8)
        memory.initializeMemory(as: UInt64.self, repeating: 0, count: Self.chunkLimit)
        chunks = UInt(bitPattern: memory)
    }

    deinit {
        for index in 0..<Self.chunkLimit {
            let address = chunkEntry(index)?.load(ordering: .acquiring) ?? 0
            UnsafeMutableRawPointer(bitPattern: UInt(truncatingIfNeeded: address))?.deallocate()
        }
        UnsafeMutableRawPointer(bitPattern: chunks)?.deallocate()
        let box = wakeBox.load(ordering: .acquiring)
        if let pointer = UnsafeRawPointer(bitPattern: UInt(truncatingIfNeeded: box)) {
            Unmanaged<WakeBox>.fromOpaque(pointer).release()
        }
    }

    /// Registrations refused because every slot was taken (not watched).
    public var registrationOverflows: UInt64 { overflows.load(ordering: .relaxed) }
    /// Times a scope woke the monitor (one wake call each): it was parked or scanning, or the scope's
    /// deadline came more than one ``minimumDeadline`` before its planned scan.
    public var wakeRequests: UInt64 { wakes.load(ordering: .relaxed) }

    /// Registers the calling thread, which runs work of kind `kind` (Chrome's `HangWatcher::ThreadType`).
    ///
    /// - Parameters:
    ///   - kind: What the thread runs (it picks the default deadline and the report's grouping).
    ///   - name: The thread's name in hang reports (a catalog string, never a person's text).
    /// - Returns: The slot; pass it to ``watch(_:deadline:)`` and ``unregister(_:)``.
    public func registerThread(_ kind: ThreadKind, name: StaticString) -> Registration {
        register(kind, name: name, port: Self.currentPort())
    }

    /// Registers a serial lane (a dispatch queue or a lane of `BackgroundWork`): its jobs may run on any
    /// thread, so each scope stores the thread that runs it (`pthread_mach_thread_np`) for the stack sample.
    ///
    /// - Parameter name: The lane's name in hang reports.
    /// - Returns: The slot.
    public func registerLane(_ name: StaticString) -> Registration {
        register(.lane, name: name, port: 0)
    }

    /// Frees a slot (the thread ends or the lane closes); its open scopes are forgotten.
    public func unregister(_ registration: Registration) {
        guard let live = liveSlot(registration) else { return }
        Self.word(live.slot, Self.deadlineWord).store(0, ordering: .releasing)
        Self.word(live.slot, Self.stateWord).compareExchange(expected: live.state, desired: live.state & ~Self.kindMask, ordering: .releasing)
    }

    /// Opens a scope on `registration`'s slot: the scope janks if it is still open after `deadline` (its
    /// budget) and hangs if it is still open ``hangAfterBudget`` later. Scopes nest; the innermost
    /// deadline applies until it closes.
    ///
    /// - Returns: The scope; it closes when it goes away (end it at the end of the unit of work).
    public func watch(_ registration: Registration, deadline: Duration = .seconds(10)) -> HangWatchScope {
        guard let live = liveSlot(registration) else {
            return HangWatchScope(registration: registration, previousDeadline: 0, slotAddress: 0, owner: nil)
        }
        let slot = live.slot
        if live.state & Self.kindMask == UInt64(ThreadKind.lane.rawValue) {
            Self.word(slot, Self.portWord).store(Self.currentPort(), ordering: .relaxed)
        }
        let (sum, overflow) = clock.nowNanos().addingReportingOverflow(timeoutNanos(deadline, slot: slot))
        let due = overflow ? Self.deadlineMask : max(min(sum, Self.deadlineMask), 1)
        // The deadline, then the plan: the monitor stores its scanning mark, then reads the slots, so
        // either it sees this deadline or this open sees the mark and wakes it. The exchange returns the
        // enclosing scope with every flag the monitor set on it, up to this instant.
        let previous = Self.word(slot, Self.deadlineWord).exchange(due, ordering: .sequentiallyConsistent)
        requestScan(by: due)
        return HangWatchScope(registration: registration, previousDeadline: previous, slotAddress: UInt(bitPattern: slot),
                              owner: self)
    }

    /// Runs `body` inside a scope on `registration`'s slot.
    ///
    /// - Returns: What `body` returns.
    public func watch<T>(_ registration: Registration, deadline: Duration = .seconds(10),
                         _ body: () throws -> T) rethrows -> T {
        let scope = watch(registration, deadline: deadline)
        let result = try body() // a throw ends `scope` as it unwinds
        scope.close()
        return result
    }

    /// Cancels the open scopes of the calling thread's slots, before a wait the thread is allowed to
    /// make: a nested run loop, a modal panel, a network or process wait (Chrome's
    /// `InvalidateActiveExpectations()`). The next scope that opens watches again.
    public func invalidateActive() {
        let port = Self.currentPort()
        for index in 0..<min(claimedEnd.load(ordering: .acquiring), Self.capacity) {
            guard let slot = slot(at: index), Self.word(slot, Self.portWord).load(ordering: .relaxed) == port else { continue }
            let word = Self.word(slot, Self.deadlineWord)
            var current = word.load(ordering: .relaxed)
            while current & Self.deadlineMask != 0, current & (Self.ignoredFlag | Self.closedFlag) == 0 {
                let (exchanged, original) = word.compareExchange(expected: current, desired: current | Self.ignoredFlag, ordering: .relaxed)
                if exchanged { break }
                current = original
            }
        }
    }

    // MARK: - Scopes

    /// Restores `previous` (the enclosing scope's packed word) when a scope closes. An enclosing scope
    /// keeps its jank and reported flags, so no tier is reported twice, and takes the ignore flag of
    /// ``invalidateActive()``; one that is watched again may need an earlier scan.
    /// The outermost scope leaves a closed mark (its own budget and ``closedFlag``), never 0: a lane busy
    /// between two scans changes its word, so the monitor keeps its period and no open has to wake it.
    /// A reported scope that ends asks for a scan now: the monitor takes its thread off what it reported
    /// hung (the crash keys' hung threads) at once, even when it was parked.
    @inline(__always)
    func close(slotAddress: UInt, registration: Registration, previous: UInt64) {
        guard let slot = UnsafeMutablePointer<UInt64>(bitPattern: slotAddress),
              Self.owns(Self.word(slot, Self.stateWord).load(ordering: .relaxed), registration) else { return }
        let word = Self.word(slot, Self.deadlineWord)
        let outermost = previous & Self.deadlineMask == 0 || previous & Self.closedFlag != 0
        // A compare-and-swap, as the monitor's mark and `invalidateActive()`'s flag are: `current` is the
        // word this close replaced, so its reported flag (the wake below) and ignore flag are never stale.
        func restoring(_ current: UInt64) -> UInt64 {
            outermost ? current & Self.deadlineMask | Self.closedFlag : previous | current & Self.ignoredFlag
        }
        var current = word.load(ordering: .relaxed)
        var restored = restoring(current)
        while case (false, let original) = word.compareExchange(expected: current, desired: restored, ordering: .sequentiallyConsistent) {
            current = original
            restored = restoring(current)
        }
        if let due = nextTierDue(restored) { requestScan(by: due) }
        if current & Self.reportedFlag != 0, restored != current { requestScan(by: clock.nowNanos()) }
    }

    /// When the scope in packed word `packed` reaches its next unreported tier: its budget, or once it
    /// janked, ``hangAfterBudget`` past it. nil: no scope, or it was reported as a hang or cancelled.
    @inline(__always)
    func nextTierDue(_ packed: UInt64) -> UInt64? {
        let budget = packed & Self.deadlineMask
        guard budget != 0, packed & Self.silencedMask == 0 else { return nil }
        guard packed & Self.jankFlag != 0 else { return budget }
        let (sum, overflow) = budget.addingReportingOverflow(hangAfterNanos)
        return overflow ? Self.deadlineMask : min(sum, Self.deadlineMask)
    }

    /// Wakes the monitor when its plan would see `due` more than one period late: it is parked or
    /// scanning (`.max`), or it sleeps to a later deadline. Within a period of the plan, nothing.
    @inline(__always)
    private func requestScan(by due: UInt64) {
        var planned = plan.load(ordering: .sequentiallyConsistent)
        while planned != 0, planned > due &+ periodNanos {
            let (exchanged, original) = plan.compareExchange(expected: planned, desired: due, ordering: .sequentiallyConsistent)
            if exchanged {
                wakes.add(1, ordering: .relaxed)
                wakeMonitor()
                return
            }
            planned = original
        }
    }

    private func wakeMonitor() {
        let box = wakeBox.load(ordering: .acquiring)
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(truncatingIfNeeded: box)) else { return }
        Unmanaged<WakeBox>.fromOpaque(pointer)._withUnsafeGuaranteedRef { $0.wake() }
    }

    /// Callers pass constants: the slot keeps its last timeout's nanoseconds (plain words of the thread or
    /// lane job that opens its scopes, one at a time), so opening skips `Duration.components`' 128-bit division.
    @inline(__always)
    private func timeoutNanos(_ timeout: Duration, slot: UnsafeMutablePointer<UInt64>) -> UInt64 {
        let cache = UnsafeMutableRawPointer(slot + Self.timeoutWord)
        let cached = slot + Self.timeoutNanosWord
        if cached.pointee != 0, cache.load(as: Duration.self) == timeout { return cached.pointee }
        let nanos = max(Self.nanos(timeout), 1)
        cache.storeBytes(of: timeout, as: Duration.self)
        cached.pointee = nanos
        return nanos
    }

    // MARK: - Slots

    private func register(_ kind: ThreadKind, name: StaticString, port: UInt64) -> Registration {
        for index in 0..<Self.capacity {
            guard let slot = slot(at: index) ?? addChunk(for: index) else { break }
            let state = Self.word(slot, Self.stateWord)
            let current = state.load(ordering: .relaxed)
            guard current & Self.kindMask == 0 else { continue }
            let next = UInt32(truncatingIfNeeded: current >> 8) &+ 1
            let generation = next == 0 ? 1 : next
            let claimed = Registration(slot: UInt32(truncatingIfNeeded: index), generation: generation)
            guard state.compareExchange(expected: current, desired: UInt64(generation) << 8 | UInt64(kind.rawValue),
                                        ordering: .acquiringAndReleasing).exchanged else { continue }
            Self.word(slot, Self.deadlineWord).store(0, ordering: .relaxed)
            Self.word(slot, Self.nameWord).store(Self.pack(name), ordering: .relaxed)
            Self.word(slot, Self.portWord).store(port, ordering: .releasing)
            (slot + Self.timeoutNanosWord).pointee = 0
            var end = claimedEnd.load(ordering: .relaxed)
            while end <= index {
                let (exchanged, original) = claimedEnd.compareExchange(expected: end, desired: index + 1, ordering: .releasing)
                if exchanged { break }
                end = original
            }
            return claimed
        }
        overflows.add(1, ordering: .relaxed)
        return Registration(slot: .max, generation: 0)
    }

    /// The slot and its state word while `registration` still owns it.
    @inline(__always)
    private func liveSlot(_ registration: Registration) -> (slot: UnsafeMutablePointer<UInt64>, state: UInt64)? {
        guard registration.generation != 0, let slot = slot(at: Int(truncatingIfNeeded: registration.slot)) else { return nil }
        let state = Self.word(slot, Self.stateWord).load(ordering: .relaxed)
        guard Self.owns(state, registration) else { return nil }
        return (slot, state)
    }

    @inline(__always)
    private func chunkEntry(_ chunk: Int) -> AtomicPointerSlot? {
        guard chunk >= 0, chunk < Self.chunkLimit,
              let table = UnsafeMutablePointer<UInt64>(bitPattern: chunks) else { return nil }
        return AtomicPointerSlot(table + chunk)
    }

    @inline(__always)
    func slot(at index: Int) -> UnsafeMutablePointer<UInt64>? {
        guard index >= 0, let entry = chunkEntry(index / Self.slotsPerChunk) else { return nil }
        let base = UInt(truncatingIfNeeded: entry.load(ordering: .acquiring))
        guard base != 0 else { return nil }
        return UnsafeMutablePointer<UInt64>(bitPattern: base &+ UInt(truncatingIfNeeded: index % Self.slotsPerChunk * Self.wordsPerSlot * 8))
    }

    /// Makes the chunk of slot `index` (zeroed, cache-line aligned); a thread that loses the race frees its own.
    private func addChunk(for index: Int) -> UnsafeMutablePointer<UInt64>? {
        guard let entry = chunkEntry(index / Self.slotsPerChunk) else { return nil }
        let bytes = Self.slotsPerChunk * Self.wordsPerSlot * 8
        let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 128)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        let address = UInt64(truncatingIfNeeded: UInt(bitPattern: memory))
        if !entry.compareExchange(expected: 0, desired: address, ordering: .acquiringAndReleasing).exchanged { memory.deallocate() }
        return slot(at: index)
    }

    // MARK: - Words and units

    static let slotsPerChunk = 64, chunkLimit = 64
    /// The most registrations at once.
    public static let capacity = slotsPerChunk * chunkLimit
    /// 16 words: one 128-byte cache line on Apple silicon.
    static let wordsPerSlot = 16
    // Slot words. The timeout cache (4 to 6) is plain memory of the scope's thread; the last word the
    // monitor saw (7) is plain memory of the monitor's thread.
    static let deadlineWord = 0, portWord = 1, stateWord = 2, nameWord = 3, timeoutWord = 4, timeoutNanosWord = 6, seenWord = 7
    /// The packed deadline (Chrome's `HangWatchDeadline`): the budget's `CLOCK_UPTIME_RAW` nanoseconds in
    /// the low 60 bits (0: no scope opened yet; 2^60 ns is 36 years of uptime), then the flags.
    static let deadlineMask: UInt64 = 1 << 60 - 1
    /// The monitor reported this scope as a hang; it is not reported again, nested or not.
    static let reportedFlag: UInt64 = 1 << 63
    /// ``invalidateActive()`` cancelled this scope and the ones around it.
    static let ignoredFlag: UInt64 = 1 << 62
    /// The monitor reported this scope as a jank (past its budget); its hang tier is still watched.
    static let jankFlag: UInt64 = 1 << 61
    /// No scope is open: the last one to close left its budget as a mark (``close(slotAddress:registration:previous:)``).
    static let closedFlag: UInt64 = 1 << 60
    /// The flags after which no tier of the word's scope is watched.
    static let silencedMask = reportedFlag | ignoredFlag | closedFlag
    /// The state word: the generation above the low byte, the ``ThreadKind`` in it (0: free).
    static let kindMask: UInt64 = 0xFF

    @inline(__always)
    static func word(_ slot: UnsafeMutablePointer<UInt64>, _ index: Int) -> AtomicPointerSlot {
        AtomicPointerSlot(slot + index)
    }

    /// Whether a slot in state `state` is still `registration`'s (claimed, same generation).
    @inline(__always)
    private static func owns(_ state: UInt64, _ registration: Registration) -> Bool {
        state & kindMask != 0 && state >> 8 == UInt64(registration.generation)
    }

    @inline(__always)
    static func currentPort() -> UInt64 {
        UInt64(truncatingIfNeeded: pthread_mach_thread_np(pthread_self()))
    }

    /// A literal's address (48 bits) and length (16 bits) in one word; 0 for a one-scalar literal.
    static func pack(_ name: StaticString) -> UInt64 {
        guard name.hasPointerRepresentation else { return 0 }
        return UInt64(truncatingIfNeeded: UInt(bitPattern: name.utf8Start)) & 0xFFFF_FFFF_FFFF
            | UInt64(clamping: min(name.utf8CodeUnitCount, 0xFFFF)) << 48
    }

    static func unpack(_ packed: UInt64) -> String {
        guard let start = UnsafePointer<UInt8>(bitPattern: UInt(truncatingIfNeeded: packed & 0xFFFF_FFFF_FFFF)) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: start, count: Int(truncatingIfNeeded: packed >> 48)), as: UTF8.self)
    }

    static func nanos(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 0 }
        let (whole, overflow) = UInt64(clamping: seconds).multipliedReportingOverflow(by: 1_000_000_000)
        let (sum, carry) = whole.addingReportingOverflow(UInt64(clamping: attoseconds / 1_000_000_000))
        return overflow || carry ? .max : sum
    }

    /// The monitor's wake, retained once (``attachMonitor(wake:)``).
    final class WakeBox: Sendable {
        let wake: @Sendable () -> Void
        init(_ wake: @escaping @Sendable () -> Void) { self.wake = wake }
    }
}

extension HangWatch {
    /// What a registered thread runs. The raw values are shared with the Rust `cmux-hang-watch` crate.
    public enum ThreadKind: UInt8, Sendable, CaseIterable {
        /// The main thread.
        case main = 1
        /// A socket or PTY reader or writer (bounded I/O only; the wait itself stays outside the scope).
        case io = 2
        /// A serial work lane (``registerLane(_:)`` registers these).
        case lane = 3
        /// A renderer thread (Ghostty's, the remote view's Metal renderer).
        case renderer = 4
        /// A thread-pool worker (a tokio worker, a `BackgroundWork` thread).
        case pool = 5
        /// A control-socket handler.
        case control = 6
    }

    /// A registered slot: its index in the slot table and the generation that tells a reused slot apart.
    public struct Registration: Sendable, Hashable {
        /// The slot's index.
        public let slot: UInt32
        /// The slot's generation when it was registered (0: no slot; its scopes watch nothing).
        public let generation: UInt32
    }
}
