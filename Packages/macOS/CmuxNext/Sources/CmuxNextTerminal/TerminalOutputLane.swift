public import Foundation
import CmuxNextWakeups
import GhosttyNextKit
import CmuxNextCompat
import CmuxNextTerminalGeometry
import CmuxNextTrace
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import os

/// Serial, non-main lane for every call that must be serialized with
/// `ghostty_surface_process_output` (ghostty.h:1373-1380, :1589):
/// output, grid locks and GHOSTSNP snapshot restores. The session's events loop queues all of
/// them here itself, without the main actor (``TerminalEventRouter``); the grid lock's generation
/// is the lane's (``TerminalGridLock``).
///
/// `process_output` takes the renderer-state mutex synchronously, so it runs
/// off the main thread (cmux-tui-contract.md 3.2).
///
/// Bounded (state-audit.md T1/T2): ``waitForCapacity()`` suspends the
/// session's event loop while more than `highWater` bytes wait to be parsed,
/// so backpressure reaches the attachment instead of piling up here, and
/// ``drained()`` waits for the backlog without blocking the main thread.
/// ``close()`` fences the lane before `ghostty_surface_free`; queued work is
/// skipped from then on, so the fence waits for at most one chunk.
nonisolated final class TerminalOutputLane: Sendable {
    let highWater: Int
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "terminal")
    private let queue: DispatchQueue
    /// Set once; work on `queue` reaches it only through ``liveSurface``.
    private let surface: UncheckedPointer
    private let closing = Atomic<Bool>(false)
    /// The surface is hidden (a parked tab or workspace): its parses run at utility, as Chrome lowers a
    /// hidden renderer's priority (`RenderProcessHostImpl::UpdateProcessPriority`), so a hidden printer never
    /// competes with the shown terminal's echo. Set by the view (``setHidden(_:)``), only while
    /// ``lowersHidden``.
    private let hidden = Atomic<Bool>(false)
    /// Hidden work runs at utility (feature `terminalStreamPriority`); false keeps every block at the queue's
    /// user-interactive QoS.
    let lowersHidden: Bool
    /// The last READY restore succeeded. Written on `queue`; history after a
    /// failed READY is skipped until the next READY.
    private let readyRestored = Atomic<Bool>(false)
    /// The surface's host-owned grid and its generation, read and changed only on `queue`.
    let gridLock = TerminalGridLock()

    private struct Backlog {
        var bytes = 0
        /// Output bytes queued for parsing (``processOutput(_:)``), in all; counted only (``outputCounts``).
        var outputQueued = 0
        var waiters: [OnceContinuation<Void, OnceContinuationError>] = []
        /// Attach readers waiting for room (``enqueueEcho(_:flow:wake:)``); each is called once.
        var wakes: [@Sendable () -> Void] = []

        typealias Released = (waiters: [OnceContinuation<Void, OnceContinuationError>], wakes: [@Sendable () -> Void])

        /// Takes every waiter and wake; the caller releases them outside the lock.
        mutating func release() -> Released {
            defer {
                waiters = []
                wakes = []
            }
            return (waiters, wakes)
        }
    }

    private let backlog = Mutex(Backlog(), rank: .terminalOutputLaneBacklog)
    /// Output bytes parsed into the live surface, and those skipped because the surface was closing. Written
    /// only on the lane's serial queue; counted only (``outputCounts``).
    private let outputParsed = Atomic<Int>(0)
    private let outputSkipped = Atomic<Int>(0)
    /// The surface's key-to-echo stage: each parsed output chunk may be a waiting key's echo. Nil
    /// while the app tracks no input latency.
    let echoStage: TerminalEchoStage?
    /// This lane's surface to the typing probe; nil marks nothing.
    let keyFlows: TypingLatencyProbe.SurfaceKey?
    /// Where the lane's output hops go (``TypingLatencyProbe/shared``, or a test's).
    private let probe: TypingLatencyProbe
    /// Watches each output chunk's parse on the lane, never the lane's queue wait; nil watches nothing.
    private let hangWatched: HangWatchedLane?
    /// One chunk's `ghostty_surface_process_output` budget (a jank past it, a hang dump 2 s later):
    /// a 256 KiB chunk parses in about a millisecond, so 100 ms means the lane is stuck.
    static let feedHangDeadline: Duration = .milliseconds(100)
    /// Parses one output chunk into the surface: `ghostty_surface_process_output`, or a test's recorder.
    typealias Parse = @Sendable (ghostty_surface_t, Data) -> Void
    /// SAFETY: called only by ``feed(_:_:)`` with the lane's live surface (``liveSurface``).
    @safe private let parse: Parse
    /// Locks the surface's grid at a generation: `ghostty_surface_set_grid`, or a test's recorder.
    typealias SetGrid = @Sendable (ghostty_surface_t, UInt16, UInt16, UInt64) -> Void
    /// SAFETY: called only by ``lockGrid(_:)`` with the lane's live surface (``liveSurface``).
    @safe private let setGrid: SetGrid
    /// Restores one GHOSTSNP phase into the surface: `ghostty_surface_restore_snapshot`, or a test's recorder.
    typealias Restore = @Sendable (ghostty_surface_t, Data, ghostty_surface_snapshot_phase_e) -> Bool
    /// SAFETY: called only by ``restoreSnapshot(_:phase:restored:)`` with the lane's live surface (``liveSurface``).
    @safe private let restore: Restore
    /// Restores a local-history READY: `ghostty_surface_restore_snapshot_local_history` (its
    /// `ghostty_surface_local_history_result_e`), or a test's recorder.
    typealias RestoreLocalHistory = @Sendable (ghostty_surface_t, Data, UInt64, Data) -> Int32
    /// SAFETY: called only by ``restoreLocalHistory(_:expectedRows:digest:grid:done:)`` with the lane's
    /// live surface (``liveSurface``).
    @safe private let restoreLocal: RestoreLocalHistory

    init(surface: ghostty_surface_t, label: String, highWater: Int = 2 << 20, echoStage: TerminalEchoStage? = nil,
         keyFlows: TypingLatencyProbe.SurfaceKey? = nil, probe: TypingLatencyProbe = .shared,
         hangs: (any HangWatchScoping)? = nil, lowersHidden: Bool = false,
         // SAFETY: the lane calls `parse`, `setGrid`, `restore` and `restoreLocal` only with its live
         // surface (their notes).
         parse: @escaping Parse = { unsafe TerminalOutputLane.processOutput($0, $1) },
         setGrid: @escaping SetGrid = { _ = unsafe ghostty_surface_set_grid($0, $1, $2, $3) },
         restore: @escaping Restore = { unsafe TerminalOutputLane.restoreSnapshot($0, $1, phase: $2) },
         restoreLocal: @escaping RestoreLocalHistory = {
             unsafe TerminalOutputLane.restoreLocalHistory($0, $1, expectedRows: $2, digest: $3)
         }) {
        // SAFETY: the view's surface, which the lane reaches only through ``liveSurface``; the view
        // closes the lane before it frees the surface (TerminalSurfaceView.deinit).
        self.surface = unsafe UncheckedPointer(raw: surface)
        // SAFETY: `parse` is called only with the live surface (its note).
        self.parse = unsafe parse
        // SAFETY: `setGrid` is called only with the live surface (its note).
        self.setGrid = unsafe setGrid
        // SAFETY: `restore` and `restoreLocal` are called only with the live surface (their notes).
        self.restore = unsafe restore
        self.restoreLocal = unsafe restoreLocal
        self.highWater = highWater
        self.echoStage = echoStage
        self.keyFlows = keyFlows
        self.probe = probe
        hangWatched = hangs.map { HangWatchedLane("terminal.feed", deadline: Self.feedHangDeadline, on: $0) }
        self.lowersHidden = lowersHidden
        if lowersHidden {
            // A queue QoS would floor every block: each carries its own instead (`enqueue`).
            // qos-allow: each block states its QoS: userInteractive while the surface shows (a frame waits), utility hidden
            self.queue = DispatchQueue(label: label)
        } else {
            // qos-allow: key echo path: a typed key's echo parses here and its frame waits for the parse
            self.queue = DispatchQueue(label: label, qos: .userInteractive)
        }
    }

    deinit {
        hangWatched?.unregister()
    }

    /// Takes a live session event for this lane off the main actor (``TerminalEventRouter``): an output
    /// chunk is queued here once the backlog has room, an echo marker marks its press. False for every
    /// other event, which the router routes.
    func takeOffMain(_ event: TerminalIOEvent) async -> Bool {
        switch event {
        case .output(let data):
            outputReceived()
            ExpectedActivity.shared.note(.terminalOutput)
            await waitForCapacity()
            processOutput(data)
            return true
        case .inputEcho(let flow):
            echoReceived(flow)
            return true
        default:
            return false
        }
    }

    /// The session took an output chunk for this lane: the `app.output.received` hop of the presses on
    /// its surface whose echo the daemon did not name (``TypingLatencyProbe/mark(_:surface:)``).
    func outputReceived() {
        if let keyFlows { probe.mark(.outputReceived, surface: keyFlows) }
    }

    /// The chunk the session just queued here carries the echo of key press `flow`
    /// (``TerminalIOEvent/inputEcho(flow:)``): that press's `app.output.received` hop now, and its
    /// `app.output.parsed` hop once the lane parsed that chunk, never another chunk's.
    func echoReceived(_ flow: UInt64) {
        probe.mark(.outputReceived, flow: flow)
        enqueue { [self] in
            guard !closing.load(ordering: .relaxed) else { return }
            probe.mark(.outputParsed, flow: flow)
        }
    }

    /// An attach link's reader hands a live chunk straight here (``TerminalEchoLane``), with no stream, task or
    /// pool thread between the socket and the parser: the chunk is queued at once, and the echo of key press
    /// `flow` it carries marks its received and parsed hops. Returns true when the backlog is now above
    /// `highWater`: the reader then waits until the lane calls `wake`, once, when it drains to `highWater` or
    /// closes. Returns false otherwise and never calls `wake`. Never blocks (the reader's thread).
    func enqueueEcho(_ data: Data, flow: UInt64?, wake: @escaping @Sendable () -> Void) -> Bool {
        outputReceived()
        ExpectedActivity.shared.note(.terminalOutput)
        processOutput(data)
        if let flow { echoReceived(flow) }
        return backlog.withLock { backlog -> Bool in
            guard backlog.bytes > highWater, !closing.load(ordering: .relaxed) else { return false }
            backlog.wakes.append(wake)
            return true
        }
    }

    /// Bytes queued but not parsed yet.
    var pendingBytes: Int { backlog.withLock { $0.bytes } }

    /// Output bytes this lane queued, parsed into its surface, and skipped because the surface was closing
    /// (`debug.surfaces`, beside the attach link's ``TerminalStreamLedger``). Counted only.
    var outputCounts: (queued: Int, parsed: Int, skipped: Int) {
        (backlog.withLock { $0.outputQueued }, outputParsed.load(ordering: .relaxed), outputSkipped.load(ordering: .relaxed))
    }

    /// The surface hid or shows again: while ``lowersHidden``, work queued from now on runs at utility while
    /// it is hidden, at user-interactive once it shows (``enqueue(_:)``). Work queued before keeps its QoS.
    func setHidden(_ isHidden: Bool) {
        guard lowersHidden else { return }
        hidden.store(isHidden, ordering: .relaxed)
    }

    /// Queues `work` on the lane. While ``lowersHidden`` it runs at the surface's QoS: user-interactive while
    /// it shows, utility while it is hidden (``setHidden(_:)``); that queue states no QoS of its own, so each
    /// block runs at the one it carries (a queue's QoS is a floor no block goes under), and a shown block
    /// queued behind a hidden one raises the running block until it is reached. Otherwise at the queue's QoS.
    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        guard lowersHidden else { return queue.async(execute: work) }
        let qos: DispatchQoS = hidden.load(ordering: .relaxed) ? .utility : .userInteractive
        queue.async(qos: qos, flags: .enforceQoS, execute: work)
    }

    func processOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        // A key armed after these bytes reached the lane cannot be their echo.
        let armedBefore = echoStage?.armedCount ?? 0
        backlog.withLock { backlog in
            backlog.bytes += data.count
            backlog.outputQueued &+= data.count
        }
        enqueue { [self] in
            defer { parsed(data.count) }
            guard let surface = liveSurface else {
                outputSkipped.add(data.count, ordering: .relaxed)
                return
            }
            // SAFETY: ``liveSurface`` on the lane: alive until close() fences the lane.
            unsafe feed(surface, data)
            outputParsed.add(data.count, ordering: .relaxed)
            echoStage?.outputParsed(armedBefore: armedBefore)
            if let keyFlows { probe.mark(.outputParsed, surface: keyFlows) }
            #if DEBUG || CMUX_BENCH_HOOKS
            if NewTerminalTrace.shared.isArmed { NewTerminalTrace.shared.parsed(lane: ObjectIdentifier(self), data) }
            #endif
        }
    }

    /// Parses one chunk on the lane, inside a ``feedHangDeadline`` hang scope when there is a watcher.
    // perf-hot: 1ms terminal-feed
    private func feed(_ surface: ghostty_surface_t, _ data: Data) {
        // SAFETY: the caller's ``liveSurface``, on the lane.
        guard let hangWatched else { return unsafe parse(surface, data) }
        // SAFETY: as above; `run` calls its body before it returns.
        hangWatched.run { unsafe parse(surface, data) }
    }

    /// The production ``Parse``: Ghostty's VT parser on the surface.
    /// `surface` is a live handle on its lane.
    static func processOutput(_ surface: ghostty_surface_t, _ data: Data) {
        // SAFETY: Ghostty reads buffer.count bytes of `data`'s storage, alive for the closure, and
        // copies what it keeps; bytes are bytes whatever the C char type.
        unsafe data.withUnsafeBytes { buffer in
            // SAFETY: as above.
            guard let base = unsafe buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            // SAFETY: as above; the caller's live surface.
            unsafe ghostty_surface_process_output(surface, base, UInt(buffer.count)) // trap-class: invariant a count is never negative
        }
    }

    /// The production ``Restore``: `ghostty_surface_restore_snapshot` of one phase.
    /// `surface` is a live handle on its lane.
    static func restoreSnapshot(_ surface: ghostty_surface_t, _ data: Data,
                                phase: ghostty_surface_snapshot_phase_e) -> Bool {
        // SAFETY: Ghostty reads buffer.count bytes of `data`'s storage, alive for the closure, and
        // copies what it keeps.
        unsafe data.withUnsafeBytes { buffer -> Bool in
            // SAFETY: as above.
            guard let base = unsafe buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            // SAFETY: as above; the caller's live surface.
            return unsafe ghostty_surface_restore_snapshot(surface, base, buffer.count, phase)
        }
    }

    /// The production ``RestoreLocalHistory``: `ghostty_surface_restore_snapshot_local_history`.
    /// `surface` is a live handle on its lane.
    static func restoreLocalHistory(_ surface: ghostty_surface_t, _ data: Data, expectedRows: UInt64,
                                    digest: Data) -> Int32 {
        // SAFETY: Ghostty reads bytes.count bytes of `data` and check.count of `digest`, both
        // storages alive for the closures, and copies what it keeps.
        unsafe data.withUnsafeBytes { bytes -> Int32 in
            // SAFETY: as above.
            unsafe digest.withUnsafeBytes { check -> Int32 in
                // SAFETY: as above.
                guard let base = unsafe bytes.bindMemory(to: UInt8.self).baseAddress,
                      let expected = unsafe check.bindMemory(to: UInt8.self).baseAddress else {
                    return GHOSTTY_SURFACE_LOCAL_HISTORY_ERROR.code
                }
                // SAFETY: as above; the caller's live surface.
                return unsafe ghostty_surface_restore_snapshot_local_history(
                    surface, base, bytes.count, expectedRows, expected, check.count)
            }
        }
    }

    /// Restores GHOSTSNP bytes (`ghostty_surface_restore_snapshot`) in
    /// stream order. Counted as backlog like output, so history pages push
    /// back on the IO the same way. A failed READY leaves the terminal as it
    /// was (logged); a failed history chunk keeps the pages applied so far.
    /// `restored` gets a READY's result on the lane, once it was restored or failed.
    func restoreSnapshot(_ data: Data, phase: ghostty_surface_snapshot_phase_e,
                         restored done: (@Sendable (Bool) -> Void)? = nil) {
        guard !data.isEmpty else { return }
        backlog.withLock { $0.bytes += data.count }
        enqueue { [self] in
            defer { parsed(data.count) }
            guard let surface = liveSurface else { return }
            let ready = phase == GHOSTTY_SURFACE_SNAPSHOT_READY
            guard ready || readyRestored.load(ordering: .relaxed) else { return }
            // SAFETY: ``liveSurface`` on the lane.
            let restored = unsafe restore(surface, data, phase)
            if ready {
                readyRestored.store(restored, ordering: .releasing)
                done?(restored)
            }
            #if DEBUG || CMUX_BENCH_HOOKS
            if NewTerminalTrace.shared.isArmed, restored { NewTerminalTrace.shared.parsed(lane: ObjectIdentifier(self), nil) }
            #endif
            if !restored {
                Self.logger.error("snapshot restore failed (phase \(phase.rawValue), \(data.count) bytes)")
            }
        }
    }

    /// Restores a READY cut at the owner's resize while keeping this
    /// terminal's history, reflowed by Ghostty to the new grid, when it
    /// matches the owner's check (`ghostty_surface_restore_snapshot_local_history`).
    /// A match restores with history; a mismatch restores the READY without
    /// history (the caller then asks for READY + history); an error changes
    /// nothing. History of a READY before it is abandoned either way.
    /// A restore (with or without history) resized the terminal and its grid lock to `grid` itself, so
    /// the lock records `grid` with no set_grid (Ghostty keeps the lock's generation). `done` gets the
    /// result (a `ghostty_surface_local_history_result_e`) on the lane.
    func restoreLocalHistory(_ data: Data, expectedRows: UInt64, digest: Data, grid: TerminalGridSize,
                             done: @escaping @Sendable (Int32) -> Void) {
        backlog.withLock { $0.bytes += data.count }
        enqueue { [self] in
            defer { parsed(data.count) }
            var result = GHOSTTY_SURFACE_LOCAL_HISTORY_ERROR.code
            defer { done(result) }
            guard let surface = liveSurface else { return }
            // SAFETY: ``liveSurface`` on the lane.
            result = unsafe restoreLocal(surface, data, expectedRows, digest)
            // A local READY replaces the old one: no history chunk may follow it.
            readyRestored.store(false, ordering: .releasing)
            if result != GHOSTTY_SURFACE_LOCAL_HISTORY_ERROR.code { gridLock.adopt(grid) }
            if result != GHOSTTY_SURFACE_LOCAL_HISTORY_RESTORED.code {
                Self.logger.error("local-history restore result \(result) (\(data.count) bytes)")
            }
        }
    }

    /// Applies the owner's Kitty image replay on Ghostty's trusted replay
    /// path (`ghostty_surface_apply_kitty_replay`: its own parser, no PTY
    /// writes; the private replay keys work only here), in stream order.
    func applyKittyReplay(_ data: Data) {
        guard !data.isEmpty else { return }
        backlog.withLock { $0.bytes += data.count }
        enqueue { [self] in
            defer { parsed(data.count) }
            guard let surface = liveSurface else { return }
            // SAFETY: ``liveSurface`` on the lane; Ghostty reads buffer.count bytes of `data`'s
            // storage, alive for the closure, and copies what it keeps.
            let applied = unsafe data.withUnsafeBytes { buffer -> Bool in
                // SAFETY: as above.
                guard let base = unsafe buffer.bindMemory(to: UInt8.self).baseAddress else { return false }
                // SAFETY: as above.
                return unsafe ghostty_surface_apply_kitty_replay(surface, base, buffer.count)
            }
            if !applied {
                Self.logger.error("kitty replay skipped part of \(data.count) bytes")
            }
        }
    }

    /// Returns once the unparsed backlog is at or below `highWater` (or the
    /// lane closed). The caller then queues its next chunk.
    func waitForCapacity() async {
        // A dropped waiter returns as a released one does; the caller queues its chunk.
        _ = try? await withOnceContinuation { (waiter: OnceContinuation<Void, OnceContinuationError>) in
            let parked = backlog.withLock { backlog -> Bool in
                guard backlog.bytes > highWater, !closing.load(ordering: .relaxed) else { return false }
                backlog.waiters.append(waiter)
                return true
            }
            if !parked { waiter.resume(returning: ()) }
        }
    }

    /// Locks the surface to `grid` in stream order, behind every chunk queued before it, at the
    /// lane's next generation (``TerminalGridLock``); nothing when `grid` is already locked.
    func lockGrid(_ grid: TerminalGridSize) {
        enqueue { [self] in
            guard let surface = liveSurface, let lock = gridLock.next(grid) else { return }
            // SAFETY: ``liveSurface`` on the lane, alive for the call (close()'s fence).
            unsafe setGrid(surface, lock.columns, lock.rows, lock.generation)
        }
    }

    /// Runs `body` on the lane with the live surface, or not at all after
    /// ``close()``.
    /// `body` must not keep the surface past its call.
    func perform(_ body: @escaping @Sendable (ghostty_surface_t) -> Void) {
        enqueue { [self] in
            guard let surface = liveSurface else { return }
            // SAFETY: ``liveSurface`` on the lane, alive for the call (close()'s fence).
            unsafe body(surface)
        }
    }

    /// Resumes once every chunk queued so far has been parsed. The session
    /// awaits this before a call that must observe the parsed state but is
    /// not lane-safe. The main thread never blocks on it.
    func drained() async {
        _ = try? await withOnceContinuation { (done: OnceContinuation<Void, OnceContinuationError>) in
            whenDrained { done.resume(returning: ()) }
        }
    }

    /// Calls `body` on the lane once every chunk queued so far has been parsed: ``drained()`` for a caller
    /// that posts its main-thread part with a class instead of awaiting.
    func whenDrained(_ body: @escaping @Sendable () -> Void) {
        enqueue(body)
    }

    /// The surface for work on `queue`; nil from ``close()`` on. Work queued after the close's fence
    /// sees `closing` set (the queue orders it after the store), so nothing touches a freed surface.
    @safe private var liveSurface: ghostty_surface_t? {
        // SAFETY: work on the lane reads it before close() sets `closing` and fences the queue,
        // which the view does before it frees the surface (TerminalSurfaceView.deinit).
        unsafe closing.load(ordering: .relaxed) ? nil : surface.raw
    }

    /// Skips queued work and waits for the chunk in flight, so nothing
    /// touches the surface afterwards. Call on the main actor immediately
    /// before `ghostty_surface_free`.
    func close() {
        closing.store(true, ordering: .relaxed)
        echoStage?.close()
        let (waiters, wakes) = backlog.withLock { $0.release() }
        waiters.forEach { $0.resume(returning: ()) }
        wakes.forEach { $0() }
        // The reviewed fence before ghostty_surface_free (BlockingAllowance.surfaceTeardown): queued chunks are
        // skipped once `closing` is set, so this waits for at most the one chunk being parsed.
        allowBlocking(.surfaceTeardown) { queue.blockingSync {} }
    }

    private func parsed(_ count: Int) {
        let (waiters, wakes) = backlog.withLock { backlog -> Backlog.Released in
            backlog.bytes -= count
            guard backlog.bytes <= highWater else { return ([], []) }
            return backlog.release()
        }
        waiters.forEach { $0.resume(returning: ()) }
        wakes.forEach { $0() }
    }
}

/// A surface's output lane as an attach link's reader feeds it (``TerminalIO/setOutputLane(_:)``): live
/// output goes from the reader thread straight to the lane, with no stream or task between them.
public nonisolated struct TerminalEchoLane: Sendable {
    let lane: TerminalOutputLane

    /// Queues one live chunk, and the echo of key press `flow` it carries. True: the lane is above its
    /// capacity, and calls `wake` once when it has room again or closes; the reader waits until then.
    /// False: it never calls `wake`. Never blocks.
    public func enqueue(_ data: Data, flow: UInt64?, wake: @escaping @Sendable () -> Void) -> Bool {
        lane.enqueueEcho(data, flow: flow, wake: wake)
    }

    /// Whether both name the same lane.
    func names(_ other: TerminalOutputLane?) -> Bool { lane === other }
}

extension ghostty_surface_local_history_result_e {
    /// The result as `ghostty_surface_restore_snapshot_local_history` returns it (a C int).
    nonisolated var code: Int32 { Int32(truncatingIfNeeded: rawValue) }
}
