import CmuxNextCompat
import Darwin

/// Input first for Swift main-actor jobs (plans/cmux-next/chrome-parity/p04-input.md section 3 (B),
/// task 076): while a person's input is pending or in dispatch, a main-actor job that is not part
/// of that input waits in a FIFO and goes to the main queue after the input's frame commits.
///
/// Chrome's UI thread runs input before other tasks by queue priority
/// (`content/browser/scheduler/browser_task_queues.h`, kUserInput) and Blink defers non-input
/// tasks while input is pending (`third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc`).
/// The Swift main executor has one FIFO, so the gate sits in front of it, at the runtime's
/// `swift_task_enqueueMainExecutor_hook` (``MainJobGateHook``).
///
/// - Classification is by origin, never by `TaskPriority` (a `Task {}` made on main inherits
///   userInteractive, an escalated job is still held). Exempt: a job enqueued on the main thread
///   while an event is in dispatch (``ExemptRule/inDispatch``), a task made by ``MainWork/input(_:)``
///   or ``MainWork/frame(_:)`` and its later jobs, and every job while a nested run loop runs.
/// - Strict FIFO: while anything is held, every job that is not exempt appends, input or not, so
///   no job overtakes one enqueued before it (SE-0431's order).
/// - Release: ``forwardOldest()`` after each frame commit while no input is pending (one job per
///   pass, so each commits before the next), and ``releaseAll(_:setting:)`` of the whole FIFO in
///   order at the one-refresh deadline, at a nested run loop's entry and at uninstall. A release
///   that stops holding sets its bit in the same critical section as the release, so no job
///   enqueued meanwhile overtakes a released one.
///
/// ```swift
/// let state = InputPendingState()
/// let gate = MainJobGate(state: state)          // MainJobGateHook.swift: forwards to the runtime
/// try MainJobGateHook().install(gate)
/// ```
public final class MainJobGate: Sendable {
    /// One job as the hook got it: the runtime's job and the enqueue it came through, as bit
    /// patterns, and the job's raw priority (the input-turn hop recorder's column only).
    struct Entry: Sendable, Equatable {
        var job: UInt
        var original: UInt
        var priority: UInt8
        /// When the gate held it (`uptimeNanos`); 0 for a job it never held.
        var heldAt: UInt64 = 0
    }

    /// Who enqueued a held job.
    public enum Origin: Int, Sendable, CaseIterable {
        case main, offMain

        var name: String { self == .main ? "main" : "off_main" }
    }

    /// Why a job passed while input was pending or in dispatch.
    public enum ExemptRule: Int, Sendable, CaseIterable {
        case inDispatch, mainWorkInput, mainWorkFrame, nestedLoop

        var name: String {
            switch self {
            case .inDispatch: "in_dispatch"
            case .mainWorkInput: "main_work_input"
            case .mainWorkFrame: "main_work_frame"
            case .nestedLoop: "nested_loop"
            }
        }
    }

    /// How held jobs left the FIFO.
    public enum Release: Int, Sendable, CaseIterable {
        /// One at a time after a commit with no input pending.
        case drained
        /// All at once, one refresh after the first was held.
        case deadline
        /// All at once, at a nested run loop's entry.
        case nestedLoop
        /// All at once, when the hook was uninstalled.
        case uninstalled

        var name: String {
            switch self {
            case .drained: "drained"
            case .deadline: "deadline"
            case .nestedLoop: "nested_loop"
            case .uninstalled: "uninstalled"
            }
        }
    }

    /// Which `MainWork` call made a stamped task.
    enum Stamp: UInt {
        case input = 0, frame = 1

        var rule: ExemptRule { self == .input ? .mainWorkInput : .mainWorkFrame }
    }

    /// The most `MainWork` tasks whose later jobs pass at once; a further one passes its first job only.
    static let stampLimit = 32

    /// The word the hook reads.
    public let state: InputPendingState
    private let forward: @Sendable (Entry) -> Void
    private let uptimeNanos: @Sendable () -> UInt64
    private let wakeMain: @Sendable () -> Void
    // concurrency-allow: the held FIFO, appended by the enqueuing thread and released on main (lock carve-out: a few array operations and non-blocking main-queue enqueues under it, never I/O, a wait or a callback into the app; the enqueues stay under it so a job that sees the FIFO empty cannot reach the main queue before the jobs released ahead of it).
    private let fifo = Mutex(HeldJobs())
    private let stamps: [GateWord] = (0..<MainJobGate.stampLimit).map { _ in GateWord() }
    private let stampCount = Atomic<Int>(0)
    private let heldCounts: [GateWord] = Origin.allCases.map { _ in GateWord() }
    private let exemptCounts: [GateWord] = ExemptRule.allCases.map { _ in GateWord() }
    private let releaseCounts: [GateWord] = Release.allCases.map { _ in GateWord() }
    private let stampOverflow = GateWord()
    /// Held jobs forwarded one refresh or more after they were held.
    private let deferredCount = GateWord()
    /// The refresh the run loop's deadline last used (``releaseIfOverdue(refreshNanos:)``): the
    /// threshold of ``Counters/deferredOverOneFrame``.
    private let lastRefreshNanos = Atomic<UInt64>(16_666_667)
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The input-turn hop recorder (task 022): every job enqueued while input is pending or in dispatch.
    private let recorder: MainJobGateDiagnostics?
    #endif

    /// The held jobs, oldest first from `head`.
    private struct HeldJobs {
        var entries: [Entry] = []
        var head = 0
        /// When the first job of this hold was held (`uptimeNanos`).
        var since: UInt64 = 0
        /// Counts holds: the run loop arms one deadline wake per hold.
        var hold: UInt64 = 0

        var isEmpty: Bool { head == entries.count }
        var count: Int { entries.count - head }

        mutating func clear() {
            entries.removeAll(keepingCapacity: true)
            head = 0
        }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// - Parameters:
    ///   - state: The word the hook reads.
    ///   - recorder: The input-turn hop recorder, or nil.
    ///   - forward: Hands a job to the main executor (the runtime's original enqueue).
    ///   - uptimeNanos: The deadline's clock (tests: a manual clock).
    ///   - wakeMain: Wakes the main run loop when a job is held, so the drain runs although the
    ///     main thread was asleep.
    init(state: InputPendingState, recorder: MainJobGateDiagnostics? = nil, forward: @escaping @Sendable (Entry) -> Void,
         uptimeNanos: @escaping @Sendable () -> UInt64 = { MainTaskPost.uptimeNanos() },
         wakeMain: @escaping @Sendable () -> Void) {
        self.state = state
        self.recorder = recorder
        self.forward = forward
        self.uptimeNanos = uptimeNanos
        self.wakeMain = wakeMain
    }
    #else
    init(state: InputPendingState, forward: @escaping @Sendable (Entry) -> Void,
         uptimeNanos: @escaping @Sendable () -> UInt64 = { MainTaskPost.uptimeNanos() },
         wakeMain: @escaping @Sendable () -> Void) {
        self.state = state
        self.forward = forward
        self.uptimeNanos = uptimeNanos
        self.wakeMain = wakeMain
    }
    #endif

    // MARK: The hook (any thread)

    /// A main-actor job: forwarded at once, or held behind pending input.
    // perf-hot: 100ns main-turn (every main-actor job's enqueue: one atomic load when quiet)
    func enqueue(_ entry: Entry) {
        let bits = state.bits
        guard !bits.isEmpty else { return forward(entry) }
        enqueue(entry, bits: bits, onMain: pthread_main_np() != 0)
    }

    /// The slow path: the word is not zero.
    @inline(never)
    func enqueue(_ entry: Entry, bits: InputPendingState.Bits, onMain: Bool) {
        // A release that stops holding is in progress: the lock orders this job after the released ones.
        if bits.contains(.held), !bits.isDisjoint(with: [.bypass, .nestedLoop]) { return hold(entry, onMain: onMain) }
        guard !bits.contains(.bypass) else { return forward(entry) }
        #if DEBUG || CMUX_BENCH_HOOKS
        if let recorder, !bits.isDisjoint(with: .input) {
            let turn = MainJobGateDiagnostics.InputTurn(pending: state.kinds, dispatching: bits.contains(.dispatching))
            recorder.recordEnqueue(turn: turn, origin: onMain ? .main : .offMain, priority: entry.priority)
        }
        #endif
        if let rule = exemption(entry.job, bits: bits, onMain: onMain) {
            if !bits.isDisjoint(with: .input) { exemptCounts[rule.rawValue].add() }
            return forward(entry)
        }
        hold(entry, onMain: onMain)
    }

    /// Why `job` passes now, or nil when it queues.
    private func exemption(_ job: UInt, bits: InputPendingState.Bits, onMain: Bool) -> ExemptRule? {
        if bits.contains(.nestedLoop) { return .nestedLoop }
        if onMain, bits.contains(.stampingInput) { return stamp(job, .input).rule }
        if onMain, bits.contains(.stampingFrame) { return stamp(job, .frame).rule }
        if let stamp = stamped(job) { return stamp.rule }
        if onMain, bits.contains(.dispatching) { return .inDispatch }
        return nil
    }

    /// Appends `entry`, or forwards it when nothing is held and holding is suspended or no input
    /// is pending or in dispatch any more (decided under the lock, against the word as it is now).
    private func hold(_ entry: Entry, onMain: Bool) {
        let first = fifo.withLock { held -> Bool? in
            let now = state.bits
            if held.isEmpty && (!now.isDisjoint(with: [.nestedLoop, .bypass]) || now.isDisjoint(with: .input)) {
                forward(entry)
                return nil
            }
            var entry = entry
            entry.heldAt = uptimeNanos()
            let first = held.isEmpty
            if first {
                held.since = entry.heldAt
                held.hold &+= 1
                state.insert(.held)
            }
            held.entries.append(entry)
            return first
        }
        guard let first else { return }
        heldCounts[(onMain ? Origin.main : .offMain).rawValue].add()
        if first { wakeMain() }
    }

    // MARK: Release (main thread; any thread is safe)

    /// Starts holding (the hook installs it).
    func start() {
        state.remove(.bypass)
    }

    /// Stops holding and releases every held job in order (the hook uninstalls it): a job that
    /// comes meanwhile passes behind them.
    func stop() {
        releaseAll(.uninstalled, setting: .bypass)
    }

    /// A nested run loop starts: releases every held job in order and holds nothing until
    /// ``exitNestedLoop()``.
    func enterNestedLoop() {
        releaseAll(.nestedLoop, setting: .nestedLoop)
    }

    /// The nested run loop ended: holding starts again.
    func exitNestedLoop() {
        state.remove(.nestedLoop)
    }

    /// Forwards the oldest held job; false when none is held.
    @discardableResult
    func forwardOldest() -> Bool {
        let forwarded = fifo.withLock { held -> Bool in
            guard !held.isEmpty else { return false }
            send(held.entries[held.head], now: uptimeNanos(), refresh: lastRefreshNanos.load(ordering: .relaxed))
            held.head += 1
            if held.isEmpty {
                held.clear()
                state.remove(.held)
            }
            return true
        }
        if forwarded { releaseCounts[Release.drained.rawValue].add() }
        return forwarded
    }

    /// Forwards every held job in order; returns how many. `bits` (``InputPendingState/Bits/bypass``,
    /// ``InputPendingState/Bits/nestedLoop``) are set in the same critical section, so a job that
    /// sees them while ``InputPendingState/Bits/held`` is still set waits for the lock and goes after.
    @discardableResult
    func releaseAll(_ reason: Release, setting bits: InputPendingState.Bits = []) -> Int {
        let released = fifo.withLock { held -> Int in
            if !bits.isEmpty { state.insert(bits) }
            let count = held.count
            guard count > 0 else { return 0 }
            let now = uptimeNanos(), refresh = lastRefreshNanos.load(ordering: .relaxed)
            for index in held.head..<held.entries.count { send(held.entries[index], now: now, refresh: refresh) }
            held.clear()
            state.remove(.held)
            return count
        }
        if released > 0 { releaseCounts[reason.rawValue].add(UInt64(released)) }
        return released
    }

    /// Forwards a held job (under the lock) and counts it when it waited `refresh` or longer.
    private func send(_ entry: Entry, now: UInt64, refresh: UInt64) {
        forward(entry)
        if now >= entry.heldAt, now - entry.heldAt >= refresh { deferredCount.add() }
    }

    /// Releases every held job when the first of them was held `refreshNanos` or longer ago.
    @discardableResult
    func releaseIfOverdue(refreshNanos: UInt64) -> Bool {
        lastRefreshNanos.store(refreshNanos, ordering: .relaxed)
        let overdue = fifo.withLock { held -> Bool in
            let now = uptimeNanos()
            return !held.isEmpty && now >= held.since && now - held.since >= refreshNanos
        }
        return overdue && releaseAll(.deadline) > 0
    }

    /// The hold in progress and the nanoseconds left until its one-refresh deadline; nil when
    /// nothing is held or the deadline has passed.
    func deadline(refreshNanos: UInt64) -> (hold: UInt64, remaining: UInt64)? {
        fifo.withLock { held -> (hold: UInt64, remaining: UInt64)? in
            guard !held.isEmpty else { return nil }
            let due = held.since &+ refreshNanos, now = uptimeNanos()
            return due > now ? (held.hold, due - now) : nil
        }
    }

    /// Jobs held now.
    var heldCount: Int { fifo.withLock { $0.count } }

    // MARK: MainWork stamps (written on the main thread only; read on any)

    /// Runs `body` (which makes one task) with the word saying `MainWork` is making it, so the
    /// hook passes the task's first job and stamps it.
    @MainActor
    func stamping<Result>(_ stamp: Stamp, _ body: () -> Result) -> Result {
        let bit: InputPendingState.Bits = stamp == .input ? .stampingInput : .stampingFrame
        state.insert(bit)
        defer { state.remove(bit) }
        return body()
    }

    /// Marks `job` so its later enqueues pass (the hook on main while stamping, the task's body).
    @discardableResult
    func stamp(_ job: UInt, _ stamp: Stamp) -> Stamp {
        guard stamped(job) == nil else { return stamp }
        guard let slot = stamps.first(where: { $0.value.load(ordering: .relaxed) == 0 }) else {
            stampOverflow.add()
            return stamp
        }
        slot.value.store(job | stamp.rawValue, ordering: .releasing)
        stampCount.add(1, ordering: .releasing)
        return stamp
    }

    /// Drops `job`'s stamp (its task's body returned).
    func unstamp(_ job: UInt) {
        guard let slot = stamps.first(where: { $0.value.load(ordering: .relaxed) & ~1 == job }) else { return }
        slot.value.store(0, ordering: .releasing)
        stampCount.subtract(1, ordering: .releasing)
    }

    /// Whether `job`'s later enqueues pass as `MainWork`'s.
    func isStamped(_ job: UInt) -> Bool { stamped(job) != nil }

    /// The stamp of `job`, or nil. Jobs are at least 16-byte aligned: bit 0 is the stamp kind.
    private func stamped(_ job: UInt) -> Stamp? {
        guard stampCount.load(ordering: .acquiring) > 0 else { return nil }
        for slot in stamps {
            let value = slot.value.load(ordering: .acquiring)
            if value != 0, value & ~1 == job { return Stamp(rawValue: value & 1) }
        }
        return nil
    }

    // MARK: Counters

    /// What the gate held and passed since launch (`debug.input` reads it).
    public struct Counters: Sendable, Equatable, Encodable {
        /// Jobs held, by ``Origin`` name.
        public var heldByOrigin: [String: UInt64]
        /// Jobs passed while input was pending or in dispatch, by ``ExemptRule`` name.
        public var exemptByRule: [String: UInt64]
        /// Jobs released, by ``Release`` name.
        public var releasedBy: [String: UInt64]
        /// `MainWork` tasks past ``MainJobGate/stampLimit``: only their first job passed.
        public var stampOverflow: UInt64
        /// Held jobs forwarded one refresh or more after they were held.
        public var deferredOverOneFrame: UInt64
        /// Jobs held now.
        public var held: Int

        enum CodingKeys: String, CodingKey {
            case heldByOrigin = "held_by_origin", exemptByRule = "exempt_by_rule", releasedBy = "released_by"
            case stampOverflow = "stamp_overflow", deferredOverOneFrame = "deferred_over_one_frame", held
        }
    }

    /// What the gate held and passed since launch.
    public var counters: Counters {
        Counters(heldByOrigin: Self.named(Origin.allCases, heldCounts, \.name),
                 exemptByRule: Self.named(ExemptRule.allCases, exemptCounts, \.name),
                 releasedBy: Self.named(Release.allCases, releaseCounts, \.name),
                 stampOverflow: UInt64(stampOverflow.value.load(ordering: .relaxed)),
                 deferredOverOneFrame: UInt64(deferredCount.value.load(ordering: .relaxed)), held: heldCount)
    }

    /// Starts the counters over (`debug.input` action `reset`); held jobs stay held.
    public func resetCounters() {
        for word in heldCounts + exemptCounts + releaseCounts + [stampOverflow, deferredCount] {
            word.value.store(0, ordering: .relaxed)
        }
    }

    private static func named<Key>(_ keys: [Key], _ words: [GateWord], _ name: (Key) -> String) -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: zip(keys, words).map { (name($0.0), UInt64($0.1.value.load(ordering: .relaxed))) })
    }
}

/// One atomic word of a fixed table (an `Atomic` cannot be an array element): a stamp slot or a counter.
final class GateWord: Sendable {
    let value = Atomic<UInt>(0)

    func add(_ count: UInt64 = 1) {
        value.add(UInt(truncatingIfNeeded: count), ordering: .relaxed)
    }
}
