#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Atomics
internal import CoreFoundation
internal import Darwin
internal import Dispatch
internal import Foundation
#if DEBUG
internal import os
#endif

/// The main-thread blocking detector's state (Debug and bench builds, Nightly to come; Release compiles it out).
///
/// One table per process (``shared``; arch-ratchet exception approved by the Performance Lead with PL-arch,
/// 2026-10-24): a violation can happen in any module, inside any lock, before the composition root exists,
/// so the check cannot take its table through `init`, the same reason Chrome keeps its thread restrictions in
/// globals. Only the checks in this module read ``shared``; other modules hold a ``BlockingDetector``. Tests
/// bind their own table with ``scoped``.
///
/// Threads. Every violation but a wrong-lane one happens on the main thread, so the main thread is the only writer of the
/// call-site index, the open allowance, the open timed call, the pending ring and the sites' counts and wall
/// times: the violation path takes no lock and calls nothing it does not own. It probes the index; for a new
/// site it writes one ring slot, then records the site in the index, and signals a user-data dispatch source.
/// When the call ends it adds its wall time and 1 to the site's atomics, so a reset during a long call puts the
/// whole call in the next window (Chrome's IOJankMonitoringWindow puts a call in the window it ends in). The
/// drain queue
/// (`com.cmuxterm.app.next.blocking-drain`, utility) empties the ring: it resolves the stack to image UUID +
/// offset frames, publishes the site, writes the Debug log line and calls the sink, so the sink never runs on
/// the thread that blocked or inside that thread's locks. A wrong-lane violation (a seam in a `.cpu` lane job,
/// ``BlockingContext/cpuLane``) happens on a lane thread: it counts in ``BlockingWrongLaneSites`` and a new site
/// goes to the drain queue the same way.
@usableFromInline
final class BlockingViolationTable: Sendable {
    /// The process's table.
    @usableFromInline static let shared = BlockingViolationTable()

    /// A test's own table: the checks in its task report there instead of to ``shared``.
    @TaskLocal static var scoped: BlockingViolationTable?

    /// The table the checks on this task report to.
    @usableFromInline static var active: BlockingViolationTable { scoped ?? shared }

    /// The most call sites one launch records (a bound, so a seam reached through unbounded paths cannot
    /// grow memory; past it a site only counts in ``overflow``).
    static let siteLimit = 128
    /// The most new sites waiting for the drain. Past it a new site counts in ``overflow`` and is not
    /// recorded yet, so its next call, after the drain caught up, records it.
    static let pendingLimit = 64

    let mode: BlockingMode
    let lockWaitLimitNanos: UInt64
    let uptimeNanos: @Sendable () -> UInt64

    // Main thread only: written and read after `pthread_main_np()` (the checks, allowBlocking, the observer).
    nonisolated(unsafe) private var index = BlockingSiteIndex(capacity: BlockingViolationTable.siteLimit) // crash-allow: main thread only (every caller checks pthread_main_np() first)
    nonisolated(unsafe) private var allowance: BlockingAllowance? // crash-allow: main thread only (every caller checks pthread_main_np() first)
    nonisolated(unsafe) private var nesting = BlockingRunLoopNesting() // crash-allow: main thread only (allowBlocking and the main run loop's observer, which runs on it)
    nonisolated(unsafe) private var timedCallOpen = false // crash-allow: main thread only (every caller checks pthread_main_np() first)
    /// One atomic count per site id; written on the main thread, read anywhere.
    nonisolated(unsafe) private let counts: UnsafeMutablePointer<UnsafeAtomic<Int>.Storage> // crash-allow: fixed allocation of atomics; every access is an atomic operation
    /// One atomic wall-time total and one maximum (nanoseconds) per site id; written on the main thread, read anywhere.
    nonisolated(unsafe) private let totalNanos: UnsafeMutablePointer<UnsafeAtomic<UInt64>.Storage> // crash-allow: fixed allocation of atomics; every access is an atomic operation
    nonisolated(unsafe) private let maxNanos: UnsafeMutablePointer<UnsafeAtomic<UInt64>.Storage> // crash-allow: fixed allocation of atomics; every access is an atomic operation
    private let ring: BlockingPendingRing
    private let overflowCount = UnsafeAtomic<Int>.create(0)
    /// The ``BlockingKind/wrongLane`` sites: seams in `.cpu` lane jobs, recorded off the main thread.
    private let wrongLane = BlockingWrongLaneSites(limit: BlockingViolationTable.siteLimit)

    private let drainQueue = DispatchQueue(label: "com.cmuxterm.app.next.blocking-drain", qos: .utility)
    nonisolated(unsafe) private let wake: any DispatchSourceUserDataAdd // crash-allow: dispatch sources are thread-safe; the main thread only adds data
    // Drain queue writes, any thread reads.
    private let published = Mutex<[PublishedSite]>([])
    private let sink = Mutex<(any BlockingViolationSink)?>(nil)
    #if DEBUG
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "blocking")
    #endif

    private struct PublishedSite {
        var id: Int
        var kind: BlockingKind
        var location: String
    }

    /// Makes a table.
    ///
    /// - Parameters:
    ///   - environment: Read for `CMUX_BLOCKING_TRAP=1` (Debug builds only: every other build records).
    ///   - mode: A test's mode; nil reads `environment`.
    ///   - lockWaitLimitNanos: The longest main-thread ``Mutex`` wait that is not a violation.
    ///   - uptimeNanos: The clock a contended ``Mutex`` wait and a ``blockingCall(_:fileID:line:_:)`` violation are
    ///     measured with.
    ///   - startsDrain: False holds the drain until ``startDrain()`` (tests fill the ring).
    init(environment: [String: String] = ProcessInfo.processInfo.environment, mode: BlockingMode? = nil,
         lockWaitLimitNanos: UInt64 = BlockingKind.lockWaitLimitNanos,
         uptimeNanos: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
         startsDrain: Bool = true) {
        #if DEBUG
        self.mode = mode ?? (environment["CMUX_BLOCKING_TRAP"] == "1" ? .trap : .record)
        #else
        self.mode = .record  // a bench (and, to come, a Nightly) never stops the app, whatever it was asked
        #endif
        self.lockWaitLimitNanos = lockWaitLimitNanos
        self.uptimeNanos = uptimeNanos
        counts = .allocate(capacity: Self.siteLimit)
        totalNanos = .allocate(capacity: Self.siteLimit)
        maxNanos = .allocate(capacity: Self.siteLimit)
        for slot in 0..<Self.siteLimit {
            (counts + slot).initialize(to: UnsafeAtomic<Int>.Storage(0))
            (totalNanos + slot).initialize(to: UnsafeAtomic<UInt64>.Storage(0))
            (maxNanos + slot).initialize(to: UnsafeAtomic<UInt64>.Storage(0))
        }
        ring = BlockingPendingRing(capacity: Self.pendingLimit)
        wake = DispatchSource.makeUserDataAddSource(queue: drainQueue)
        wake.setEventHandler { [weak self] in self?.drain() }
        if startsDrain { wake.activate() }
    }

    deinit {
        wake.cancel()
        wake.activate()  // a source that never ran must be activated to be released
        counts.deinitialize(count: Self.siteLimit)
        counts.deallocate()
        totalNanos.deinitialize(count: Self.siteLimit)
        totalNanos.deallocate()
        maxNanos.deinitialize(count: Self.siteLimit)
        maxNanos.deallocate()
        overflowCount.destroy()
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
        table.addCall(site: site, nanos: nil)
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
            defer { table.addCall(site: site, nanos: nil) }
            return try body()
        }
        table.timedCallOpen = true
        let start = table.uptimeNanos()
        defer {
            let nanos = table.uptimeNanos() &- start
            table.timedCallOpen = false
            table.addCall(site: site, nanos: nanos)
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
        addCall(site: site, nanos: timedCallOpen ? nil : nanos)
    }

    /// Checks the call and returns its site id, or nil when it is allowed or not recorded (the table or the
    /// ring was full). The caller counts the call when it ends (``addCall(site:nanos:)``).
    private func recordedSite(_ kind: BlockingKind, fileID: StaticString, line: UInt) -> Int? {
        guard allowance == nil else { return nil }
        #if DEBUG
        if mode == .trap && kind != .lockWait {
            fatalError("blocking \(kind.rawValue) on the main thread at \(fileID):\(line): move it off the main thread, or "
                + "wrap it in allowBlocking(<reviewed reason>) (plans/cmux-next/threading-model.md)")
        }
        #endif
        let key = BlockingSiteKey(fileID: fileID, line: line)
        if let id = index.find(key) { return id }
        guard let id = index.nextID else {
            overflowCount.wrappingIncrement(ordering: .relaxed)
            return nil
        }
        var pending = BlockingPendingCall(kind: kind, site: id, fileID: fileID, line: line)
        pending.captureStack()
        guard ring.push(pending) else {
            overflowCount.wrappingIncrement(ordering: .relaxed)
            return nil
        }
        index.insert(key)
        wake.add(data: 1)
        return id
    }

    /// Counts one ended call at `site` and adds its `nanos` (nil: not timed) to the site's total and maximum.
    private func addCall(site: Int, nanos: UInt64?) {
        if let nanos {
            UnsafeAtomic<UInt64>(at: totalNanos + site).wrappingIncrement(by: nanos, ordering: .relaxed)
            let maximum = UnsafeAtomic<UInt64>(at: maxNanos + site)
            var seen = maximum.load(ordering: .relaxed)
            while nanos > seen {
                let (exchanged, original) = maximum.weakCompareExchange(expected: seen, desired: nanos, ordering: .relaxed)
                if exchanged { break }
                seen = original
            }
        }
        UnsafeAtomic<Int>(at: counts + site).wrappingIncrement(ordering: .relaxed)
    }

    // MARK: the wrong-lane path (lane threads)

    /// A blocking seam (`kind`) ran in a job of BackgroundWork's `.cpu` lane (``BlockingContext/cpuLane``), which
    /// must not block: the site counts as ``BlockingKind/wrongLane``. A new site is logged and sent to the sink on the
    /// drain queue, as a main-thread site is. Recorded only, never a trap: the job runs on its own lane thread, and
    /// the fix is to move it to `.files` or `.system`.
    @usableFromInline @inline(never)
    static func blockedInWrongLane(_ kind: BlockingKind, fileID: StaticString, line: UInt) {
        active.wrongLaneBlocked(kind, fileID: fileID, line: line)
    }

    private func wrongLaneBlocked(_ kind: BlockingKind, fileID: StaticString, line: UInt) {
        guard wrongLane.record(fileID: fileID, line: line) else { return }
        var pending = BlockingPendingCall(kind: .wrongLane, site: -1, fileID: fileID, line: line)
        pending.captureStack()
        let call = pending
        drainQueue.async { [self] in reportWrongLane(call, seam: kind) }
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

    private func drain() {
        var resolver = BlockingFrameResolver()
        while let pending = ring.pop() {
            let location = "\(pending.fileID):\(pending.line)"
            published.withLock { $0.append(PublishedSite(id: pending.site, kind: pending.kind, location: location)) }
            #if DEBUG
            logger.error("blocking \(pending.kind.rawValue, privacy: .public) on the main thread at \(location, privacy: .public): move it off the main thread, or wrap it in allowBlocking(<reviewed reason>) (plans/cmux-next/threading-model.md)")
            #endif
            guard let sink = sink.withLock({ $0 }) else { continue }
            sink.record(BlockingViolation(kind: pending.kind, frames: resolver.frames(pending.stack)))
        }
    }

    private func reportWrongLane(_ pending: BlockingPendingCall, seam kind: BlockingKind) {
        #if DEBUG
        let location = "\(pending.fileID):\(pending.line)"
        logger.error("blocking \(kind.rawValue, privacy: .public) in a .cpu lane job at \(location, privacy: .public): the .cpu lane must not block; run the job on .files or .system (plans/cmux-next/threading-model.md)")
        #endif
        guard let sink = sink.withLock({ $0 }) else { return }
        var resolver = BlockingFrameResolver()
        sink.record(BlockingViolation(kind: .wrongLane, frames: resolver.frames(pending.stack)))
    }

    /// Waits until the drain has handled every site recorded before the call (tests).
    func flush() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            drainQueue.async { [self] in
                drain()
                done.resume()
            }
        }
    }

    // MARK: readers (any thread)

    func install(sink: (any BlockingViolationSink)?) {
        self.sink.withLock { $0 = sink }
    }

    var sites: [BlockingSite] {
        published.withLock { $0 }.map { site in
            BlockingSite(kind: site.kind, location: site.location,
                         count: UnsafeAtomic<Int>(at: counts + site.id).load(ordering: .relaxed),
                         totalNanos: UnsafeAtomic<UInt64>(at: totalNanos + site.id).load(ordering: .relaxed),
                         maxNanos: UnsafeAtomic<UInt64>(at: maxNanos + site.id).load(ordering: .relaxed))
        } + wrongLane.sites
    }

    var overflow: Int { overflowCount.load(ordering: .relaxed) + wrongLane.overflow }

    func resetCounts() {
        for slot in 0..<Self.siteLimit {
            UnsafeAtomic<Int>(at: counts + slot).store(0, ordering: .relaxed)
            UnsafeAtomic<UInt64>(at: totalNanos + slot).store(0, ordering: .relaxed)
            UnsafeAtomic<UInt64>(at: maxNanos + slot).store(0, ordering: .relaxed)
        }
        wrongLane.resetCounts()
    }
}
#endif
