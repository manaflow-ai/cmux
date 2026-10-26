import CmuxNextCompat
import CmuxNextSettings
import Darwin
import Foundation

/// Reports work that runs past its deadline on any thread: Chrome's `base::HangWatcher`
/// (base/threading/hang_watcher.cc), cmux's ``HangWatching``. Named apart from CmuxNextTrace's
/// `HangWatchScope`, which this module also imports.
///
/// Each thread that enters a scope gets a slot on first use, in its own cache line: the scope's
/// deadline, the thread's Mach port (`pthread_mach_thread_np`), the scope's name and its start. At
/// most `capacity` threads (512) get one; the others are counted in ``slotOverflows`` and not
/// watched. Entering is one `mach_absolute_time` read and four atomic stores; leaving is one store.
/// Neither takes a lock nor makes a system call, except to wake the watcher (below).
///
/// One watcher thread scans the slots. While a scope is armed, and for one `period` after the
/// last, it sleeps until the earliest deadline, at most one period, so a scope that enters with a
/// deadline at least one period away never wakes it. With nothing armed it parks with no timer:
/// an idle process has no watcher wakeup, where Chrome's watcher polls every 10 s. A scope that
/// enters while the watcher is parked, or with a deadline before the watcher's planned wake,
/// signals its semaphore (``wakeRequests``; a system call only when the watcher is waiting). A scope shorter than the period that enters
/// during a scan may be reported up to one period late.
///
/// An overrun is reported once per scope, while it still runs: the thread's stack
/// (``ThreadStackSampler``), the thread's and the scope's names and how long it has run, into
/// ``log`` (`debug.hangs`, kind `hang`) and to the sink given to ``start(onHang:)``.
public final class ThreadHangWatcher: HangWatching {
    /// One scope still running past its deadline.
    public struct Report: Sendable {
        /// The thread's name as the kernel holds it; empty when unnamed.
        public var thread: String
        /// The scope's name (``HangWatching/enter(_:deadline:)``).
        public var scope: String
        /// How long the scope had run when it was sampled.
        public var elapsed: Duration
        /// The scope's deadline, from its start.
        public var timeout: Duration
        /// The thread's return addresses, innermost first; empty when sampling failed.
        public var addresses: [UInt]
    }

    public let log: HangLog
    public let capacity: Int
    private let periodTicks: UInt64
    private let timebase: Timebase
    /// The slot table's address (owned until deinit, as TraceRing keeps its ring's): its shared words are
    /// read and written only through AtomicPointerSlot; the timeout cache only by the slot's own thread,
    /// the reported word only by the watcher thread.
    private let table: UInt
    private let key: pthread_key_t
    private let hasKey: Bool
    /// One past the highest slot index ever claimed: the watcher scans no further.
    private let claimedEnd = Atomic<Int>(0)
    /// The `mach_absolute_time` at which the watcher next scans: 0 before ``start(onHang:)`` and
    /// after ``stop()`` (no scope wakes it), `.max` while it is parked (every scope wakes it).
    private let nextScan = Atomic<UInt64>(0)
    private let overflows = Atomic<UInt64>(0)
    private let wakes = Atomic<UInt64>(0)
    private let running = Atomic<Bool>(false)
    /// The watcher's only wait: signaled by a scope that must wake it, and by ``stop()``.
    // concurrency-allow: only the watcher thread waits on it (waitForWake); scopes and stop() only signal it.
    private let wake = DispatchSemaphore(value: 0)
    #if DEBUG
    /// Times the watcher thread returned from a wait (tests count its idle wakeups).
    let watcherWakes = Atomic<UInt64>(0)
    #endif

    // Slot words. The timeout cache (4 to 6) is plain memory of the slot's own thread; the deadline
    // last reported (7) is plain memory of the watcher thread.
    private static let deadlineWord = 0, portWord = 1, nameWord = 2, startWord = 3, cachedTimeoutWord = 4, cachedTicksWord = 6,
                       reportedWord = 7
    /// 16 words: one 128-byte cache line on Apple silicon, so two threads never share one.
    private static let wordsPerSlot = 16

    /// A watcher for up to `capacity` threads that checks armed scopes at least once per `period`
    /// (the shortest deadline its scopes use), recording into `log`.
    public init(log: HangLog, capacity: Int = 512, period: Duration = .milliseconds(100)) {
        let count = max(1, capacity)
        var info = mach_timebase_info_data_t()
        let base = mach_timebase_info(&info) == KERN_SUCCESS && info.numer != 0 && info.denom != 0
            ? Timebase(numer: info.numer, denom: info.denom) : Timebase(numer: 1, denom: 1)
        self.log = log
        self.capacity = count
        timebase = base
        periodTicks = max(Self.ticks(nanos: Self.nanos(period), base), 1)
        let bytes = count * Self.wordsPerSlot * MemoryLayout<UInt64>.stride
        let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 128)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        table = UInt(bitPattern: memory)
        var key = pthread_key_t()
        // A thread that ends frees its slot (TSD destructor; no captures, a C function).
        hasKey = pthread_key_create(&key, { ThreadHangWatcher.release(slotAt: $0) }) == 0
        self.key = key
    }

    deinit {
        if hasKey { pthread_key_delete(key) } // clears every thread's value: no destructor runs later
        UnsafeMutableRawPointer(bitPattern: table)?.deallocate()
    }

    /// Threads that found every slot taken (not watched).
    public var slotOverflows: UInt64 { overflows.load(ordering: .relaxed) }
    /// Times a scope woke the watcher (one semaphore signal each): it was parked, or the scope's
    /// deadline came before its planned wake.
    public var wakeRequests: UInt64 { wakes.load(ordering: .relaxed) }
    var isParked: Bool { nextScan.load(ordering: .acquiring) == .max }

    // MARK: - Scopes (any thread)

    public func enter(_ name: StaticString, deadline timeout: Duration) -> HangWatchToken {
        guard let slot = currentSlot() else { return .unwatched }
        let now = mach_absolute_time()
        let (sum, overflow) = now.addingReportingOverflow(timeoutTicks(timeout, slot: slot))
        let token = HangWatchToken(slot: UInt(bitPattern: slot), previousDeadline: Self.word(slot, Self.deadlineWord).load(ordering: .relaxed),
                                   previousName: Self.word(slot, Self.nameWord).load(ordering: .relaxed),
                                   previousStart: Self.word(slot, Self.startWord).load(ordering: .relaxed))
        arm(slot, deadline: overflow ? UInt64.max - 1 : min(sum, UInt64.max - 1), name: Self.pack(name), start: now,
            armed: token.previousDeadline != 0)
        return token
    }

    public func leave(_ token: HangWatchToken) {
        guard let slot = UnsafeMutablePointer<UInt64>(bitPattern: token.slot) else { return }
        guard token.previousDeadline != 0 else {
            Self.word(slot, Self.deadlineWord).store(0, ordering: .releasing)
            return
        }
        arm(slot, deadline: token.previousDeadline, name: token.previousName, start: token.previousStart, armed: true)
    }

    /// Writes one scope into `slot`. The watcher takes a slot's name and start only when its deadline
    /// reads the same before and after them, so an armed slot is disarmed while they change.
    @inline(__always)
    private func arm(_ slot: UnsafeMutablePointer<UInt64>, deadline: UInt64, name: UInt64, start: UInt64, armed: Bool) {
        if armed { Self.word(slot, Self.deadlineWord).store(0, ordering: .relaxed) }
        Self.word(slot, Self.nameWord).store(name, ordering: .releasing)
        Self.word(slot, Self.startWord).store(start, ordering: .releasing)
        // Deadline stored, then the plan read; the watcher stores `.max`, then scans: one sees the other.
        Self.word(slot, Self.deadlineWord).store(deadline, ordering: .sequentiallyConsistent)
        var planned = nextScan.load(ordering: .sequentiallyConsistent)
        while deadline < planned {
            let (exchanged, original) = nextScan.compareExchange(expected: planned, desired: deadline, ordering: .sequentiallyConsistent)
            if exchanged {
                wakes.add(1, ordering: .relaxed)
                wake.signal()
                return
            }
            planned = original
        }
    }

    @inline(__always)
    private func currentSlot() -> UnsafeMutablePointer<UInt64>? {
        guard hasKey else { return nil }
        guard let value = pthread_getspecific(key) else { return claimSlot() }
        return Int(bitPattern: value) == 1 ? nil : value.assumingMemoryBound(to: UInt64.self)
    }

    /// The calling thread's first scope: a free slot (port 0) becomes its own until it ends.
    private func claimSlot() -> UnsafeMutablePointer<UInt64>? {
        let port = UInt64(truncatingIfNeeded: pthread_mach_thread_np(pthread_self()))
        for index in 0..<capacity {
            guard let slot = slot(at: index) else { break }
            guard Self.word(slot, Self.portWord).compareExchange(expected: 0, desired: port, ordering: .acquiringAndReleasing).exchanged else { continue }
            var end = claimedEnd.load(ordering: .relaxed)
            while end <= index {
                let (exchanged, original) = claimedEnd.compareExchange(expected: end, desired: index + 1, ordering: .releasing)
                if exchanged { break }
                end = original
            }
            pthread_setspecific(key, slot)
            return slot
        }
        overflows.add(1, ordering: .relaxed)
        pthread_setspecific(key, UnsafeRawPointer(bitPattern: 1)) // marks the thread: it does not search again
        return nil
    }

    private static func release(slotAt value: UnsafeMutableRawPointer) {
        guard Int(bitPattern: value) != 1 else { return }
        let slot = value.assumingMemoryBound(to: UInt64.self)
        word(slot, deadlineWord).store(0, ordering: .relaxed)
        word(slot, portWord).store(0, ordering: .releasing)
    }

    /// Callers pass constants: the slot keeps its last timeout's ticks, so entering skips
    /// `Duration.components`' 128-bit division.
    @inline(__always)
    private func timeoutTicks(_ timeout: Duration, slot: UnsafeMutablePointer<UInt64>) -> UInt64 {
        let cache = UnsafeMutableRawPointer(slot + Self.cachedTimeoutWord)
        let cachedTicks = slot + Self.cachedTicksWord
        if cachedTicks.pointee != 0, cache.load(as: Duration.self) == timeout { return cachedTicks.pointee }
        let ticks = max(Self.ticks(nanos: Self.nanos(timeout), timebase), 1)
        cache.storeBytes(of: timeout, as: Duration.self)
        cachedTicks.pointee = ticks
        return ticks
    }

    // MARK: - Watcher thread

    /// Starts the watcher thread (once). `onHang` gets each report on that thread; it must return
    /// soon and never wait for the thread it reports.
    public func start(onHang: (@Sendable (Report) -> Void)? = nil) {
        guard running.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        nextScan.store(.max, ordering: .sequentiallyConsistent)
        let thread = Thread { [self] in watch(onHang: onHang) }
        thread.name = "cmux-next thread hang watcher"
        thread.qualityOfService = .default
        thread.start()
    }

    public func stop() {
        guard running.compareExchange(expected: true, desired: false, ordering: .acquiringAndReleasing).exchanged else { return }
        nextScan.store(0, ordering: .sequentiallyConsistent)
        wake.signal()
    }

    private func watch(onHang: (@Sendable (Report) -> Void)?) {
        var quietScans = 1 // nothing armed yet: the first quiet scan parks
        while running.load(ordering: .acquiring) {
            let now = mach_absolute_time()
            var pass = scan(now: now, onHang: onHang)
            quietScans = pass.armed ? 0 : quietScans + 1
            if quietScans >= 2 {
                nextScan.store(.max, ordering: .sequentiallyConsistent)
                pass = scan(now: mach_absolute_time(), onHang: onHang)
                if !pass.armed {
                    waitForWake(until: nil)
                    quietScans = 0 // woken by a scope: linger one period after it, for the next one
                    continue
                }
                quietScans = 0
            }
            let plan = min(pass.earliest, now &+ periodTicks)
            nextScan.store(plan, ordering: .sequentiallyConsistent)
            if plan > mach_absolute_time() { waitForWake(until: plan) }
        }
    }

    /// Reports each slot past its deadline once; returns whether any is armed and the earliest
    /// deadline still ahead.
    private func scan(now: UInt64, onHang: (@Sendable (Report) -> Void)?) -> (armed: Bool, earliest: UInt64) {
        var armed = false
        var earliest = UInt64.max
        for index in 0..<min(claimedEnd.load(ordering: .acquiring), capacity) {
            guard let slot = slot(at: index) else { break }
            let deadline = Self.word(slot, Self.deadlineWord).load(ordering: .sequentiallyConsistent)
            guard deadline != 0 else { continue }
            armed = true
            if deadline > now {
                earliest = min(earliest, deadline)
            } else if (slot + Self.reportedWord).pointee != deadline {
                (slot + Self.reportedWord).pointee = deadline
                report(slot, deadline: deadline, now: now, onHang: onHang)
            }
        }
        return (armed, earliest)
    }

    private func report(_ slot: UnsafeMutablePointer<UInt64>, deadline: UInt64, now: UInt64, onHang: (@Sendable (Report) -> Void)?) {
        let port = Self.word(slot, Self.portWord).load(ordering: .acquiring)
        let name = Self.word(slot, Self.nameWord).load(ordering: .acquiring)
        let start = Self.word(slot, Self.startWord).load(ordering: .acquiring)
        // A deadline that moved while the others were read belongs to another scope.
        guard Self.word(slot, Self.deadlineWord).load(ordering: .acquiring) == deadline, port != 0, start <= deadline else { return }
        let thread = thread_act_t(truncatingIfNeeded: port)
        let addresses = ThreadStackSampler(thread: thread).sample()
        // The thread ended meanwhile: its port may name another thread now.
        guard Self.word(slot, Self.portWord).load(ordering: .acquiring) == port else { return }
        let report = Report(thread: ThreadStackSampler.threadName(thread), scope: Self.unpack(name),
                            elapsed: .nanoseconds(Int64(clamping: Self.nanos(ticks: now > start ? now - start : 0, timebase))),
                            timeout: .nanoseconds(Int64(clamping: Self.nanos(ticks: deadline - start, timebase))), addresses: addresses)
        log.append(startUptimeNanos: Self.nanos(ticks: start, timebase), duration: report.elapsed, addresses: addresses, kind: .hang,
                   details: ["thread": .string(report.thread), "scope": .string(report.scope),
                             "timeout_ms": .number(report.timeout.fractionalMilliseconds)])
        onHang?(report)
    }

    /// Waits until a scope or ``stop()`` signals, or until `deadline` (`mach_absolute_time`; nil: no
    /// limit). Signals that came while the watcher scanned end the next wait at once: one extra scan.
    private func waitForWake(until deadline: UInt64?) {
        if let deadline {
            wake.blockingWait(timeout: DispatchTime(uptimeNanoseconds: Self.nanos(ticks: deadline, timebase)))
        } else {
            wake.blockingWait()
        }
        #if DEBUG
        watcherWakes.add(1, ordering: .relaxed)
        #endif
    }

    // MARK: - Words and units

    private func slot(at index: Int) -> UnsafeMutablePointer<UInt64>? {
        UnsafeMutablePointer<UInt64>(bitPattern: table &+ UInt(truncatingIfNeeded: index * Self.wordsPerSlot * MemoryLayout<UInt64>.stride))
    }

    @inline(__always)
    private static func word(_ slot: UnsafeMutablePointer<UInt64>, _ index: Int) -> AtomicPointerSlot {
        AtomicPointerSlot(slot + index)
    }

    /// A literal's address (48 bits) and length (16 bits) in one word; 0 for a one-scalar literal.
    @inline(__always)
    private static func pack(_ name: StaticString) -> UInt64 {
        guard name.hasPointerRepresentation else { return 0 }
        return UInt64(truncatingIfNeeded: UInt(bitPattern: name.utf8Start)) & 0xFFFF_FFFF_FFFF
            | UInt64(clamping: min(name.utf8CodeUnitCount, 0xFFFF)) << 48
    }

    private static func unpack(_ packed: UInt64) -> String {
        guard let start = UnsafePointer<UInt8>(bitPattern: UInt(truncatingIfNeeded: packed & 0xFFFF_FFFF_FFFF)) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: start, count: Int(truncatingIfNeeded: packed >> 48)), as: UTF8.self)
    }

    private static func nanos(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 0 }
        let (whole, overflow) = UInt64(clamping: seconds).multipliedReportingOverflow(by: 1_000_000_000)
        return overflow ? .max : whole.addingReportingOverflow(UInt64(clamping: attoseconds / 1_000_000_000)).partialValue
    }

    /// `value * multiplier / divisor` without overflow; `.max` when the result does not fit.
    private static func scale(_ value: UInt64, by multiplier: UInt32, over divisor: UInt32) -> UInt64 {
        let wideDivisor = UInt64(truncatingIfNeeded: divisor)
        let product = value.multipliedFullWidth(by: UInt64(truncatingIfNeeded: multiplier))
        guard product.high < wideDivisor else { return .max }
        return wideDivisor.dividingFullWidth(product).quotient
    }

    private static func ticks(nanos: UInt64, _ base: Timebase) -> UInt64 { scale(nanos, by: base.denom, over: base.numer) }
    private static func nanos(ticks: UInt64, _ base: Timebase) -> UInt64 { scale(ticks, by: base.numer, over: base.denom) }

    /// `mach_absolute_time` ticks are `numer / denom` nanoseconds.
    private struct Timebase: Sendable {
        var numer: UInt32
        var denom: UInt32
    }
}
