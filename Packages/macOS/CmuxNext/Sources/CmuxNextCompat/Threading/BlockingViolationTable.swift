#if DEBUG || CMUX_BLOCKING_CHECKS
internal import Atomics
internal import CoreFoundation
internal import Darwin
internal import Dispatch
internal import Foundation
internal import os

/// The main-thread blocking detector's state (Debug, bench and Nightly builds; Release compiles it out).
///
/// One table per process (``shared``; arch-ratchet exception approved by the Performance Lead with PL-arch,
/// 2026-10-24): a violation can happen in any module, inside any lock, before the composition root exists,
/// so the check cannot take its table through `init`, the same reason Chrome keeps its thread restrictions in
/// globals. Only the checks in this module read ``shared``; other modules hold a ``BlockingDetector``. Tests
/// bind their own table with ``scoped``.
///
/// Threads. Every violation happens on the main thread, so the main thread is the only writer of the
/// call-site index, the open allowance and the pending ring: the violation path takes no lock and calls nothing
/// it does not own. It probes the index and adds 1 to the site's atomic count; for a new site it writes one
/// ring slot, then records the site in the index, and signals a user-data dispatch source. The drain queue
/// (`com.cmuxterm.app.next.blocking-drain`, utility) empties the ring: it resolves the stack to image UUID +
/// offset frames, publishes the site, writes the Debug log line and calls the sink, so the sink never runs on
/// the thread that blocked or inside that thread's locks.
///
/// Trap mode (`CMUX_BLOCKING_TRAP=1`, read once at init, in any checked build). Chrome's configurable DCHECK
/// (base/check.h `DCHECK_IS_CONFIGURABLE`): a Nightly records and continues, and a launch that opts in stops at
/// the call. Before it stops, the main thread hands the site to the sink through the drain queue and waits for
/// it at most ``defaultTrapFlushMilliseconds`` (so the hang report keeps the call that ended the process),
/// then logs one fault.
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
    /// The longest a trap waits for the sink to take the site that stops the process (a sink that waits on a
    /// lock the main thread holds must not turn the trap into a hang).
    static let defaultTrapFlushMilliseconds = 50

    let mode: BlockingMode
    let trapFlushMilliseconds: Int
    let lockWaitLimitNanos: UInt64
    let uptimeNanos: @Sendable () -> UInt64

    // Main thread only: written and read after `pthread_main_np()` (the checks, allowBlocking, the observer).
    nonisolated(unsafe) private var index = BlockingSiteIndex(capacity: BlockingViolationTable.siteLimit) // crash-allow: main thread only (every caller checks pthread_main_np() first)
    nonisolated(unsafe) private var allowance: BlockingAllowance? // crash-allow: main thread only (every caller checks pthread_main_np() first)
    nonisolated(unsafe) private var nesting = BlockingRunLoopNesting() // crash-allow: main thread only (allowBlocking and the main run loop's observer, which runs on it)
    /// One atomic count per site id; written on the main thread, read anywhere.
    nonisolated(unsafe) private let counts: UnsafeMutablePointer<UnsafeAtomic<Int>.Storage> // crash-allow: fixed allocation of atomics; every access is an atomic operation
    private let ring: BlockingPendingRing
    private let overflowCount = UnsafeAtomic<Int>.create(0)

    private let drainQueue = DispatchQueue(label: "com.cmuxterm.app.next.blocking-drain", qos: .utility)
    nonisolated(unsafe) private let wake: any DispatchSourceUserDataAdd // crash-allow: dispatch sources are thread-safe; the main thread only adds data
    // Drain queue writes, any thread reads.
    private let published = Mutex<[PublishedSite]>([])
    private let sink = Mutex<(any BlockingViolationSink)?>(nil)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "blocking")

    private struct PublishedSite {
        var id: Int
        var kind: BlockingKind
        var location: String
    }

    /// Makes a table.
    ///
    /// - Parameters:
    ///   - environment: Read once, here, for `CMUX_BLOCKING_TRAP=1` (``BlockingMode/init(environment:)``).
    ///   - mode: A test's mode; nil reads `environment`.
    ///   - lockWaitLimitNanos: The longest main-thread ``Mutex`` wait that is not a violation.
    ///   - uptimeNanos: The clock a contended ``Mutex`` wait is measured with.
    ///   - trapFlushMilliseconds: The longest a trap waits for the sink (``flushBeforeTrap()``).
    ///   - startsDrain: False holds the drain until ``startDrain()`` (tests fill the ring).
    init(environment: [String: String] = ProcessInfo.processInfo.environment, mode: BlockingMode? = nil,
         lockWaitLimitNanos: UInt64 = BlockingKind.lockWaitLimitNanos,
         uptimeNanos: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
         trapFlushMilliseconds: Int = BlockingViolationTable.defaultTrapFlushMilliseconds,
         startsDrain: Bool = true) {
        self.mode = mode ?? BlockingMode(environment: environment)
        self.trapFlushMilliseconds = trapFlushMilliseconds
        self.lockWaitLimitNanos = lockWaitLimitNanos
        self.uptimeNanos = uptimeNanos
        counts = .allocate(capacity: Self.siteLimit)
        for slot in 0..<Self.siteLimit { (counts + slot).initialize(to: UnsafeAtomic<Int>.Storage(0)) }
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
        overflowCount.destroy()
    }

    /// Lets a table made with `startsDrain: false` drain.
    func startDrain() {
        wake.activate()
    }

    // MARK: the violation path (main thread)

    /// A blocking seam ran on the main thread (``assertBlockingAllowed(_:fileID:line:)``).
    @usableFromInline @inline(never)
    static func mainThreadBlocked(_ kind: BlockingKind, fileID: StaticString, line: UInt) {
        active.blocked(kind, fileID: fileID, line: line)
    }

    /// The main thread waited longer than ``lockWaitLimitNanos`` for a contended ``Mutex`` at the `withLock`
    /// call `fileID`:`line`. Recorded only, never a trap in any mode: the measured wait includes the time the
    /// main thread waited to be scheduled, so a loaded host must not stop the app on it.
    @inline(never)
    func mainThreadWaitedForLock(fileID: StaticString, line: UInt) {
        blocked(.lockWait, fileID: fileID, line: line)
    }

    private func blocked(_ kind: BlockingKind, fileID: StaticString, line: UInt) {
        guard allowance == nil else { return }
        record(kind, fileID: fileID, line: line)
        if mode == .trap && kind != .lockWait { trap(kind, fileID: fileID, line: line) }
    }

    private func record(_ kind: BlockingKind, fileID: StaticString, line: UInt) {
        let key = BlockingSiteKey(fileID: fileID, line: line)
        if let id = index.find(key) {
            UnsafeAtomic<Int>(at: counts + id).wrappingIncrement(ordering: .relaxed)
            return
        }
        guard let id = index.nextID else {
            overflowCount.wrappingIncrement(ordering: .relaxed)
            return
        }
        var pending = BlockingPendingCall(kind: kind, site: id, fileID: fileID, line: line)
        pending.captureStack()
        guard ring.push(pending) else {
            overflowCount.wrappingIncrement(ordering: .relaxed)
            return
        }
        UnsafeAtomic<Int>(at: counts + id).store(1, ordering: .relaxed)
        index.insert(key)
        wake.add(data: 1)
    }

    /// Trap mode's end: the sink gets the site (``flushBeforeTrap()``), one fault goes to the unified log,
    /// then the process stops at the call.
    @inline(never)
    private func trap(_ kind: BlockingKind, fileID: StaticString, line: UInt) -> Never {
        let location = "\(fileID):\(line)"
        _ = flushBeforeTrap()
        logger.fault("blocking \(kind.rawValue, privacy: .public) on the main thread at \(location, privacy: .public): stopping (CMUX_BLOCKING_TRAP=1)")
        fatalError("blocking \(kind.rawValue) on the main thread at \(location): move it off the main thread, or "
            + "wrap it in allowBlocking(<reviewed reason>) (plans/cmux-next/threading-model.md)")
    }

    /// Runs the drain now and waits for it at most ``trapFlushMilliseconds``: a trap's last step, so the sink has
    /// the site that stops the process. The wait raises the drain to the waiter's priority
    /// (`DispatchWorkItem.wait`), and the bound keeps a sink stuck on a lock the main thread holds from
    /// turning the trap into a hang.
    ///
    /// - Returns: `.success` when the sink took every pending site in time.
    func flushBeforeTrap() -> DispatchTimeoutResult {
        let handOff = DispatchWorkItem(qos: .userInteractive, flags: .enforceQoS) { [self] in drain() }
        drainQueue.async(execute: handOff)
        return handOff.wait(timeout: .now() + .milliseconds(trapFlushMilliseconds)) // concurrency-allow: only the opt-in trap path waits, bounded at 50 ms, and the process stops right after; the main thread never resumes
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
                         count: UnsafeAtomic<Int>(at: counts + site.id).load(ordering: .relaxed))
        }
    }

    var overflow: Int { overflowCount.load(ordering: .relaxed) }

    func resetCounts() {
        for slot in 0..<Self.siteLimit { UnsafeAtomic<Int>(at: counts + slot).store(0, ordering: .relaxed) }
    }
}
#endif
