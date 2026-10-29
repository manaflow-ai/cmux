#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Atomics
internal import CoreFoundation
internal import Darwin
internal import Dispatch
internal import Foundation
internal import class CmuxSafeConcurrency.OnceContinuation
internal import enum CmuxSafeConcurrency.OnceContinuationError
internal import func CmuxSafeConcurrency.withOnceContinuation
internal import os

/// The blocking detector's state (Debug, bench-checks and Nightly builds; Release compiles it out): the
/// violations on the main thread, on the shared pools (``BlockingContext/pool``: the Swift cooperative pool
/// and GCD root queues), in items of BackgroundWork's `.cpu` lane (``BlockingContext/cpuLane``, each recorded
/// as ``BlockingKind/wrongLane``) and the sync primitives in items of the lanes that may block
/// (``BlockingContext/laneSync``).
///
/// One table per process (``shared``; arch-ratchet exception approved by the Performance Lead with PL-arch,
/// 2026-10-24): a violation can happen in any module, inside any lock, before the composition root exists,
/// so the check cannot take its table through `init`, the same reason Chrome keeps its thread restrictions in
/// globals. Only the checks in this module read ``shared``; other modules hold a ``BlockingDetector``. Tests
/// bind their own table with ``scoped``.
///
/// Threads. The main thread is the only writer of the main call-site index, the open allowance, the open timed
/// call and the main pending ring: the main violation path takes no lock and calls nothing it does not own. It
/// probes the index; for a new site it writes one ring slot, then records the site in the index, and signals a
/// user-data dispatch source. Pool, `.cpu` lane and lane-sync violations come from many threads at once, each
/// context in its own ``BlockingOffMainSites``: a repeat of a known site probes its index with no lock; only a new
/// site takes that context's short lock, to take its id and push to its ring (a dedicated thread never takes it,
/// nor a lane's call that is not a sync primitive), and each thread keeps its own open timed call in its
/// ``BlockingThreadFlags``. When a call ends it adds its wall time and 1 to the site's atomics, so a reset during
/// a long call puts the whole call in the next window (Chrome's IOJankMonitoringWindow puts a call in the window
/// it ends in). The drain queue
/// (`com.cmuxterm.app.next.blocking-drain`, utility) empties the rings: it resolves the stack to image UUID +
/// offset frames, publishes the site, writes the Debug log line and calls the sink, so the sink never runs on
/// the thread that blocked or inside that thread's locks.
///
/// Main-thread trap mode (`CMUX_BLOCKING_TRAP=1`, read once at init, in a Debug or Nightly build; a bench build
/// ignores it, ``BlockingMode/resolved(environment:)``). Chrome's configurable DCHECK (base/check.h
/// `DCHECK_IS_CONFIGURABLE`): a checked build records and continues, and a launch that opts in stops at the call.
/// Before it stops, the main thread records the site, hands it to the sink through the drain queue and waits for
/// it at most ``defaultTrapFlushMilliseconds`` (so the hang report keeps the call that ended the process), then
/// logs one fault (``trapFault``).
@usableFromInline
final class BlockingViolationTable: Sendable {
    /// The process's table.
    @usableFromInline static let shared = BlockingViolationTable()

    /// A test's own table: the checks in its task report there instead of to ``shared``.
    @TaskLocal static var scoped: BlockingViolationTable?

    /// The table the checks on this task report to.
    @usableFromInline static var active: BlockingViolationTable { scoped ?? shared }

    /// The most call sites one launch records per context (a bound, so a seam reached through unbounded paths
    /// cannot grow memory; past it a site only counts in its context's ``overflow(in:)``).
    static let siteLimit = 128
    /// The most new sites per context waiting for the drain. Past it a new site counts in its context's
    /// ``overflow(in:)`` and is not recorded yet, so its next call, after the drain caught up, records it.
    static let pendingLimit = 64
    /// The longest a main-thread trap waits for the sink to take the site that stops the process (a sink that
    /// waits on a lock the main thread holds must not turn the trap into a hang).
    static let defaultTrapFlushMilliseconds = 50

    let mode: BlockingMode
    /// What a pool violation does: ``BlockingMode/record`` unless a Debug build was started with
    /// `CMUX_BLOCKING_TRAP_POOL=1`.
    let poolMode: BlockingMode
    let trapFlushMilliseconds: Int
    let lockWaitLimitNanos: UInt64
    let uptimeNanos: @Sendable () -> UInt64
    /// Writes a main-thread trap's one fault, after the flush and before the stop (``logFault(_:)`` outside tests).
    let trapFault: @Sendable (_ message: String) -> Void

    // Main thread only: written and read after `pthread_main_np()` (the checks, allowBlocking, the observer).
    nonisolated(unsafe) private var index = BlockingSiteIndex(capacity: BlockingViolationTable.siteLimit) // crash-allow: main thread only (every caller checks pthread_main_np() first)
    nonisolated(unsafe) private var allowance: BlockingAllowance? // crash-allow: main thread only (every caller checks pthread_main_np() first)
    nonisolated(unsafe) private var nesting = BlockingRunLoopNesting() // crash-allow: main thread only (allowBlocking and the main run loop's observer, which runs on it)
    nonisolated(unsafe) private var timedCallOpen = false // crash-allow: main thread only (every caller checks pthread_main_np() first)
    private let mainCounters = BlockingSiteCounters(capacity: BlockingViolationTable.siteLimit)
    private let ring: BlockingPendingRing
    private let mainOverflow = UnsafeAtomic<Int>.create(0)
    /// How many ``resetCounts()`` finished: stored after the zeroing, so a reader that loads it first sees the
    /// zeroed counters whenever it sees the new value.
    private let resets = UnsafeAtomic<Int>.create(0)
    private let pool = BlockingOffMainSites(siteLimit: BlockingViolationTable.siteLimit,
                                            pendingLimit: BlockingViolationTable.pendingLimit)
    /// The ``BlockingKind/wrongLane`` sites: seams in items of BackgroundWork's `.cpu` lane.
    private let cpuLane = BlockingOffMainSites(siteLimit: BlockingViolationTable.siteLimit,
                                               pendingLimit: BlockingViolationTable.pendingLimit)
    /// The ``BlockingContext/laneSync`` sites: sync primitives in items of the lanes that may block.
    private let laneSync = BlockingOffMainSites(siteLimit: BlockingViolationTable.siteLimit,
                                                pendingLimit: BlockingViolationTable.pendingLimit)
    /// The QoS inversions of the waiting seams (``BlockingViolationTable/qosWait(onto:fileID:line:)``).
    let qosInversions = BlockingQoSInversions()

    private let drainQueue = DispatchQueue(label: "com.cmuxterm.app.next.blocking-drain", qos: .utility)
    nonisolated(unsafe) private let wake: any DispatchSourceUserDataAdd // crash-allow: dispatch sources are thread-safe; recording threads only add data
    // Drain queue writes, any thread reads.
    private let published = Mutex<[PublishedSite]>([])
    private let sink = Mutex<(any BlockingViolationSink)?>(nil)
    nonisolated(unsafe) private var drainWatch: BlockingDrainWatch? // crash-allow: drain queue only (watchDrain sets it in a block on drainQueue; every drain-queue job reads it there)
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "blocking")

    /// Writes `message` as one unified-log fault (`category == "blocking"`): a trap's default ``trapFault``.
    ///
    /// - Parameter message: The violation and its call site.
    static func logFault(_ message: String) {
        logger.fault("\(message, privacy: .public)")
    }

    private struct PublishedSite {
        var id: Int
        var context: BlockingContext
        var kind: BlockingKind
        var seamKind: BlockingKind
        var location: String
        /// What the sink got, or, for a site drained before a sink was installed, gets at install.
        var violation: BlockingViolation
    }

    /// Makes a table.
    ///
    /// - Parameters:
    ///   - environment: Read once, here, for `CMUX_BLOCKING_TRAP=1` (``BlockingMode/resolved(environment:)``: Debug
    ///     and Nightly; a bench build records) and `CMUX_BLOCKING_TRAP_POOL=1` (Debug builds only: every other build
    ///     records).
    ///   - mode: A test's main-thread mode; nil reads `environment`.
    ///   - poolMode: A test's pool mode; nil reads `environment`.
    ///   - lockWaitLimitNanos: The longest ``Mutex`` wait on the main thread or in a lane item that is not a
    ///     violation.
    ///   - uptimeNanos: The clock a contended ``Mutex`` wait and a ``blockingCall(_:fileID:line:_:)`` violation are
    ///     measured with.
    ///   - trapFlushMilliseconds: The longest a main-thread trap waits for the sink (``flushBeforeTrap()``).
    ///   - trapFault: Writes a main-thread trap's fault (a test checks it comes after the flush and before the stop).
    ///   - startsDrain: False holds the drain until ``startDrain()`` (tests fill the ring).
    init(environment: [String: String] = ProcessInfo.processInfo.environment, mode: BlockingMode? = nil,
         poolMode: BlockingMode? = nil, lockWaitLimitNanos: UInt64 = BlockingKind.lockWaitLimitNanos,
         uptimeNanos: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
         trapFlushMilliseconds: Int = BlockingViolationTable.defaultTrapFlushMilliseconds,
         trapFault: @escaping @Sendable (_ message: String) -> Void = { BlockingViolationTable.logFault($0) },
         startsDrain: Bool = true) {
        self.mode = mode ?? BlockingMode.resolved(environment: environment)
        #if DEBUG
        self.poolMode = poolMode ?? (environment["CMUX_BLOCKING_TRAP_POOL"] == "1" ? .trap : .record)
        #else
        // The pool trap is Debug only: a Nightly's opt-in crash mode covers the main thread.
        self.poolMode = .record
        #endif
        self.trapFlushMilliseconds = trapFlushMilliseconds
        self.trapFault = trapFault
        self.lockWaitLimitNanos = lockWaitLimitNanos
        self.uptimeNanos = uptimeNanos
        ring = BlockingPendingRing(capacity: Self.pendingLimit)
        wake = DispatchSource.makeUserDataAddSource(queue: drainQueue)
        wake.setEventHandler { [weak self] in
            guard let self else { return }
            watched { drain() }
        }
        if startsDrain { wake.activate() }
    }

    deinit {
        wake.cancel()
        wake.activate()  // a source that never ran must be activated to be released
        mainOverflow.destroy()
        resets.destroy()
    }

    /// Lets a table made with `startsDrain: false` drain.
    func startDrain() {
        wake.activate()
    }

    // MARK: the violation path (main thread)

    /// A blocking call with no body to time ran on the main thread (``assertBlockingAllowed(_:fileID:line:)``):
    /// its site counts it without time.
    @usableFromInline @inline(never)
    static func mainThreadBlocked(_ kind: BlockingKind, fileID: StaticString, line: UInt) {
        let table = active
        guard let site = table.recordedSite(kind, fileID: fileID, line: line) else { return }
        table.mainCounters.add(site: site, nanos: nil)
    }

    /// ``blockingCall(_:fileID:line:_:)`` on the main thread: checks the call and, when it is a recorded
    /// violation, times `body` and adds the time to the site. Only the outermost timed call is timed, as Chrome
    /// times only a `ScopedBlockingCall` with no previous one (base/threading/scoped_blocking_call_internal.cc):
    /// a call inside it (a seam in `blockingSync`'s work, or work a nested run of the main run loop does during
    /// `waitUntilExit`, which handles no input) counts without time, so no interval is counted twice.
    @usableFromInline @inline(never)
    static func mainThreadBlockingCall<Result, Failure: Error>(
        _ kind: BlockingKind, fileID: StaticString, line: UInt, _ body: () throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let table = active
        guard let site = table.recordedSite(kind, fileID: fileID, line: line) else { return try body() }
        guard !table.timedCallOpen else {
            defer { table.mainCounters.add(site: site, nanos: nil) }
            return try body()
        }
        table.timedCallOpen = true
        let start = table.uptimeNanos()
        defer {
            let nanos = table.uptimeNanos() &- start
            table.timedCallOpen = false
            table.mainCounters.add(site: site, nanos: nanos)
        }
        return try body()
    }

    /// The main thread waited `nanos`, longer than ``lockWaitLimitNanos``, for a contended ``Mutex`` at the
    /// `withLock` call `fileID`:`line`; the wait adds to the site like a timed call (without time inside a timed
    /// call, which already counts it). Recorded only, never a trap in any mode: the measured wait includes the
    /// time the main thread waited to be scheduled, so a loaded host must not stop the app on it.
    @inline(never)
    func mainThreadWaitedForLock(fileID: StaticString, line: UInt, nanos: UInt64) {
        guard let site = recordedSite(.lockWait, fileID: fileID, line: line) else { return }
        mainCounters.add(site: site, nanos: timedCallOpen ? nil : nanos)
    }

    /// Checks the call and returns its site id, or nil when it is allowed or not recorded (the table or the
    /// ring was full). The caller counts the call when it ends (``BlockingSiteCounters/add(site:nanos:)``). In trap
    /// mode a violation that is not record-only is recorded first, then stops the process (``trapOnMain(_:fileID:line:)``).
    private func recordedSite(_ kind: BlockingKind, fileID: StaticString, line: UInt) -> Int? {
        guard allowance == nil else { return nil }
        let site = newOrKnownSite(kind, fileID: fileID, line: line)
        if mode == .trap && !kind.isRecordOnly { trapOnMain(kind, fileID: fileID, line: line) }
        return site
    }

    /// The main-thread site of a violation: a known site's id, or a new one pushed to the ring for the drain; nil
    /// when the table or the ring was full.
    private func newOrKnownSite(_ kind: BlockingKind, fileID: StaticString, line: UInt) -> Int? {
        let key = BlockingSiteKey(fileID: fileID, line: line)
        if let id = index.find(key) { return id }
        guard let id = index.nextID else {
            mainOverflow.wrappingIncrement(ordering: .relaxed)
            return nil
        }
        var pending = BlockingPendingCall(kind: kind, site: id, fileID: fileID, line: line)
        pending.captureStack()
        guard ring.push(pending) else {
            mainOverflow.wrappingIncrement(ordering: .relaxed)
            return nil
        }
        index.insert(key)
        wake.add(data: 1)
        return id
    }

    /// Main-thread trap mode's end (`CMUX_BLOCKING_TRAP=1` in a Debug or Nightly build, and the detector's tests):
    /// the sink gets the site (``flushBeforeTrap()``), one fault goes to the unified log (``trapFault``), then the
    /// process stops at the call.
    @inline(never)
    private func trapOnMain(_ kind: BlockingKind, fileID: StaticString, line: UInt) -> Never {
        let location = "\(fileID):\(line)"
        _ = flushBeforeTrap()
        trapFault("blocking \(kind.rawValue) on the main thread at \(location): stopping (CMUX_BLOCKING_TRAP=1)")
        Self.trap("blocking \(kind.rawValue) on the main thread at \(location): move it off the main thread, or "
            + "wrap it in allowBlocking(<reviewed reason>) (plans/cmux-next/threading-model.md)")
    }

    /// Runs the drain now and waits for it at most ``trapFlushMilliseconds``: a main-thread trap's last step, so
    /// the sink has the site that stops the process. The wait raises the drain to the waiter's priority
    /// (`DispatchWorkItem.wait`), and the bound keeps a sink stuck on a lock the main thread holds from turning
    /// the trap into a hang.
    ///
    /// - Returns: `.success` when the sink took every pending site in time.
    func flushBeforeTrap() -> DispatchTimeoutResult {
        let handOff = DispatchWorkItem(qos: .userInteractive, flags: .enforceQoS) { [self] in watched { drain() } }
        drainQueue.async(execute: handOff)
        return handOff.wait(timeout: .now() + .milliseconds(trapFlushMilliseconds)) // concurrency-allow: only the opt-in trap path waits, bounded at 50 ms, and the process stops right after; the main thread never resumes
    }

    /// Trap mode's stop: a main-thread trap after its flush and fault (``trapOnMain(_:fileID:line:)``), and a pool
    /// trap (Debug only: `CMUX_BLOCKING_TRAP_POOL=1` and the detector's tests).
    private static func trap(_ message: String) -> Never {
        fatalError(message)
    }

    // MARK: the off-main path (a pool thread, a `.cpu` lane item, a sync primitive in a lane item)

    /// The sites of an off-main violation context (``BlockingContext/offMainViolation(_:)``).
    private func offMainSites(_ context: BlockingContext) -> BlockingOffMainSites {
        switch context {
        case .cpuLane: cpuLane
        case .laneSync: laneSync
        case .main, .pool, .lane, .dedicated: pool
        }
    }

    /// ``blockingCall(_:fileID:line:_:)`` on a thread where ``BlockingContext/offMainViolation(_:)`` found the call
    /// a violation in `context` (``BlockingContext/pool``, ``BlockingContext/cpuLane`` or
    /// ``BlockingContext/laneSync``), timed like a main-thread one. Only the outermost timed call on the thread is
    /// timed; a call inside it counts without time.
    @usableFromInline @inline(never)
    static func offMainBlockingCall<Result, Failure: Error>(
        _ kind: BlockingKind, in context: BlockingContext, fileID: StaticString, line: UInt,
        _ body: () throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let table = active
        guard let site = table.recordedOffMainSite(kind, in: context, fileID: fileID, line: line) else {
            return try body()
        }
        let counters = table.offMainSites(context).counters
        let flags = BlockingThreadFlags.load()
        guard !flags.timedCallOpen else {
            defer { counters.add(site: site, nanos: nil) }
            return try body()
        }
        BlockingThreadFlags.store(flags.withTimedCallOpen())
        let start = table.uptimeNanos()
        defer {
            let nanos = table.uptimeNanos() &- start
            BlockingThreadFlags.store(flags)
            counters.add(site: site, nanos: nanos)
        }
        return try body()
    }

    /// ``assertBlockingAllowed(_:fileID:line:)`` off the main thread in `context`: the call counts at its site
    /// without time.
    @usableFromInline @inline(never)
    static func offMainBlocked(_ kind: BlockingKind, in context: BlockingContext, fileID: StaticString, line: UInt) {
        let table = active
        guard let site = table.recordedOffMainSite(kind, in: context, fileID: fileID, line: line) else { return }
        table.offMainSites(context).counters.add(site: site, nanos: nil)
    }

    /// A lane item waited `nanos`, longer than ``lockWaitLimitNanos``, for a contended ``Mutex`` at the `withLock`
    /// call `fileID`:`line`: a ``BlockingKind/lockWait`` site in `context` (``BlockingContext/laneSync``, or
    /// ``BlockingContext/cpuLane`` as ``BlockingKind/wrongLane``) with the wait as its time (without time inside a
    /// timed call on the thread, which already counts it). Never a trap.
    @inline(never)
    func laneWaitedForLock(in context: BlockingContext, fileID: StaticString, line: UInt, nanos: UInt64) {
        guard let site = recordedOffMainSite(.lockWait, in: context, fileID: fileID, line: line) else { return }
        offMainSites(context).counters.add(site: site, nanos: BlockingThreadFlags.load().timedCallOpen ? nil : nanos)
    }

    /// The off-main twin of ``recordedSite(_:fileID:line:)``: the site id of a call in `context`, or nil when it
    /// is not recorded (that context's table or ring was full). A known site is one lock-free probe. A new site
    /// walks its stack in this frame, as the main path does (so both keep the same caller frames), then
    /// ``BlockingOffMainSites/insert(_:key:)`` takes its id and pushes it to the ring.
    ///
    /// A `.cpu` lane call is recorded as ``BlockingKind/wrongLane`` with its seam's own kind beside it, and never
    /// traps: the item runs on its own lane slot, and the fix is to move it to the lane the seam kind names. A
    /// lane-sync call keeps its own kind and never traps either: the lane may block, so it stalls only its slot.
    private func recordedOffMainSite(_ kind: BlockingKind, in context: BlockingContext, fileID: StaticString,
                                     line: UInt) -> Int? {
        #if DEBUG
        if context == .pool && poolMode == .trap {
            Self.trap("blocking \(kind.rawValue) on the cooperative pool or a GCD root queue at \(fileID):\(line): "
                + "run it on a BackgroundWork lane, work.run(_:mayBlock:) (plans/cmux-next/threading-model.md)")
        }
        #endif
        let sites = offMainSites(context)
        let key = BlockingSiteKey(fileID: fileID, line: line)
        if let id = sites.find(key) { return id }
        guard !sites.isFull else {
            sites.countOverflow()
            return nil
        }
        var pending = BlockingPendingCall(kind: context == .cpuLane ? .wrongLane : kind, seamKind: kind, site: -1,
                                          fileID: fileID, line: line)
        pending.captureStack()
        guard let recorded = sites.insert(pending, key: key) else {
            sites.countOverflow()
            return nil
        }
        if recorded.isNew { wake.add(data: 1) }
        return recorded.id
    }

    // MARK: allowance (main thread)

    /// Opens `reason` for the synchronous body of ``allowBlocking(_:_:)`` and returns what to pass to
    /// ``leaveAllowance(_:)``.
    @usableFromInline
    func enterAllowance(_ reason: BlockingAllowance) -> BlockingAllowanceToken {
        let token = BlockingAllowanceToken(previous: allowance, wasOpen: nesting.isOpen)
        allowance = reason
        nesting.enter { [weak self] nested in self?.runLoopNested(nested) }
        return token
    }

    /// Closes the allowance ``enterAllowance(_:)`` opened.
    @usableFromInline
    func leaveAllowance(_ token: BlockingAllowanceToken) {
        nesting.leave(wasOpen: token.wasOpen)
        allowance = token.previous
    }

    /// The main run loop entered (`true`) or left (`false`) a nested run inside an open allowance: a nested
    /// run (a modal panel, `waitUntilExit`, `RunLoop.run(until:)`) runs other main-thread work, which the
    /// allowance's reason does not cover, so the allowance is held back until the nested run returns.
    private func runLoopNested(_ nested: Bool) {
        if nested {
            nesting.held.append(allowance)
            allowance = nil
        } else if let held = nesting.held.popLast() {
            allowance = held
        }
    }

    // MARK: the drain (drain queue)

    /// Runs one drain-queue job inside the composition root's hang-watch scope, when it set one
    /// (``watchDrain(_:)``): one scope per job.
    private func watched(_ job: () -> Void) {
        guard let drainWatch else { return job() }
        drainWatch(job)
    }

    private func drain() {
        var resolver = BlockingFrameResolver()
        drain(ring, context: .main, &resolver)
        drain(pool.ring, context: .pool, &resolver)
        drain(cpuLane.ring, context: .cpuLane, &resolver)
        drain(laneSync.ring, context: .laneSync, &resolver)
        qosInversions.drain()
    }

    /// Wakes the drain for a new site recorded outside the violation contexts (a QoS inversion).
    func wakeDrain() {
        wake.add(data: 1)
    }

    private func drain(_ ring: BlockingPendingRing, context: BlockingContext, _ resolver: inout BlockingFrameResolver) {
        while let pending = ring.pop() {
            let location = "\(pending.fileID):\(pending.line)"
            let violation = BlockingViolation(kind: pending.kind, context: context, frames: resolver.frames(pending.stack),
                                              seamKind: pending.seamKind)
            published.withLock {
                $0.append(PublishedSite(id: pending.site, context: context, kind: pending.kind,
                                        seamKind: pending.seamKind, location: location, violation: violation))
            }
            #if DEBUG
            // A fault, not an error: a new site is a bug to fix, and a fault is kept in the
            // persistent log and shown by `log show` without --info or --debug.
            switch context {
            case .pool:
                Self.logger.fault("blocking \(pending.kind.rawValue, privacy: .public) on the cooperative pool or a GCD root queue at \(location, privacy: .public): run it on a BackgroundWork lane (plans/cmux-next/threading-model.md)")
            case .cpuLane:
                Self.logger.fault("blocking \(pending.seamKind.rawValue, privacy: .public) in a .cpu lane item at \(location, privacy: .public): the .cpu lane is sized to the cores and must not block; run the item on \(Self.mayBlockLane(for: pending.seamKind), privacy: .public) (plans/cmux-next/threading-model.md)")
            case .laneSync:
                Self.logger.fault("blocking \(pending.kind.rawValue, privacy: .public) on a sync primitive in a BackgroundWork lane item at \(location, privacy: .public): a lane may block on the disk or a socket but not wait for other work; await that work, or run the wait on a dedicated thread (plans/cmux-next/threading-model.md)")
            case .main, .lane, .dedicated:
                Self.logger.fault("blocking \(pending.kind.rawValue, privacy: .public) on the main thread at \(location, privacy: .public): move it off the main thread, or wrap it in allowBlocking(<reviewed reason>) (plans/cmux-next/threading-model.md)")
            }
            #endif
            sink.withLock { $0 }?.record(violation)
        }
    }

    #if DEBUG
    /// The BackgroundWork lane a `.cpu` item whose seam waits on `seamKind` belongs on: disk I/O (file data,
    /// file metadata, SQLite) on `.files`, any other wait (a socket, a process, a system framework, a sleep) on
    /// `.system`.
    private static func mayBlockLane(for seamKind: BlockingKind) -> String {
        switch seamKind {
        case .fileIO, .fsMetadata, .sqlite: ".files"
        default: ".system"
        }
    }
    #endif

    /// Waits until the drain has handled every site recorded before the call (tests).
    func flush() async {
        _ = try? await withOnceContinuation { (done: OnceContinuation<Void, OnceContinuationError>) in
            drainQueue.async { [self] in
                watched { drain() }
                done.resume(returning: ())
            }
        }
    }

    // MARK: readers (any thread)

    /// Installs `sink` on the drain queue and, in the same turn, hands it every site drained before
    /// (the launch's sites before the composition root ran): the drain runs on that queue too, so each
    /// site reaches the sink once, by this replay or by the drain.
    func install(sink: (any BlockingViolationSink)?) {
        drainQueue.async { [self] in
            self.sink.withLock { $0 = sink }
            guard let sink else { return }
            watched {
                for site in published.withLock({ $0 }) { sink.record(site.violation) }
            }
        }
    }

    /// Sets, on the drain queue, what runs each later drain-queue job (``BlockingDetector/watchDrain(_:)``).
    func watchDrain(_ watch: BlockingDrainWatch?) {
        drainQueue.async { [self] in drainWatch = watch }
    }

    /// Every published site of every context, in the order each first reached the drain.
    var sites: [BlockingSite] {
        published.withLock { $0 }.map { site in
            let counters = site.context == .main ? mainCounters : offMainSites(site.context).counters
            let read = counters.read(site: site.id)
            return BlockingSite(kind: site.kind, location: site.location, count: read.count,
                                totalNanos: read.totalNanos, maxNanos: read.maxNanos, context: site.context,
                                seamKind: site.seamKind)
        }
    }

    /// Blocking calls of every context not recorded as a site.
    var overflow: Int {
        overflow(in: .main) + overflow(in: .pool) + overflow(in: .cpuLane) + overflow(in: .laneSync)
    }

    /// Blocking calls in `context` not recorded as a site: its table was full, or its ring held
    /// ``pendingLimit`` new sites (0 for a context that may block).
    func overflow(in context: BlockingContext) -> Int {
        switch context {
        case .main: mainOverflow.load(ordering: .relaxed)
        case .pool: pool.overflow
        case .cpuLane: cpuLane.overflow
        case .laneSync: laneSync.overflow
        case .lane, .dedicated: 0
        }
    }

    /// How many ``resetCounts()`` finished (load it before the sites it is read with).
    var resetCount: Int { resets.load(ordering: .acquiring) }

    func resetCounts() {
        mainCounters.reset()
        pool.counters.reset()
        cpuLane.counters.reset()
        laneSync.counters.reset()
        qosInversions.resetCounts()
        resets.wrappingIncrement(ordering: .releasing)
    }
}
#endif
