public import Foundation
import CmuxNextWakeups
import GhosttyNextKit
import CmuxNextCompat
import CmuxNextTrace
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import os

/// Serial, non-main lane for every call that must be serialized with
/// `ghostty_surface_process_output` (ghostty.h:1373-1380, :1589):
/// output, grid locks and GHOSTSNP snapshot restores.
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
    /// The last READY restore succeeded. Written on `queue`; history after a
    /// failed READY is skipped until the next READY.
    private let readyRestored = Atomic<Bool>(false)
    /// Whether the last READY restored (read after ``drained()``).
    var lastReadyRestored: Bool { readyRestored.load(ordering: .acquiring) }
    /// Result of the last local-history restore (a
    /// `ghostty_surface_local_history_result_e`; read after ``drained()``).
    private let localHistoryResult = Atomic<Int32>(Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_ERROR.rawValue))
    var lastLocalHistoryResult: Int32 { localHistoryResult.load(ordering: .acquiring) }

    private struct Backlog {
        var bytes = 0
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

    private let backlog = Mutex(Backlog())
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

    init(surface: ghostty_surface_t, label: String, highWater: Int = 2 << 20, echoStage: TerminalEchoStage? = nil,
         keyFlows: TypingLatencyProbe.SurfaceKey? = nil, probe: TypingLatencyProbe = .shared,
         hangs: (any HangWatchScoping)? = nil,
         // SAFETY: the lane calls `parse` only with its live surface (`parse`'s note).
         parse: @escaping Parse = { unsafe TerminalOutputLane.processOutput($0, $1) }) {
        // SAFETY: the view's surface, which the lane reaches only through ``liveSurface``; the view
        // closes the lane before it frees the surface (TerminalSurfaceView.deinit).
        self.surface = unsafe UncheckedPointer(raw: surface)
        // SAFETY: `parse` is called only with the live surface (its note).
        self.parse = unsafe parse
        self.highWater = highWater
        self.echoStage = echoStage
        self.keyFlows = keyFlows
        self.probe = probe
        hangWatched = hangs.map { HangWatchedLane("terminal.feed", deadline: Self.feedHangDeadline, on: $0) }
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    deinit {
        hangWatched?.unregister()
    }

    /// Takes a live session event for this lane off the main actor (``TerminalSession``): an output
    /// chunk is queued here once the backlog has room, an echo marker marks its press. False for every
    /// other event, which the session handles on the main actor.
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
        queue.async { [self] in
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

    func processOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        // A key armed after these bytes reached the lane cannot be their echo.
        let armedBefore = echoStage?.armedCount ?? 0
        backlog.withLock { $0.bytes += data.count }
        queue.async { [self] in
            defer { parsed(data.count) }
            guard let surface = liveSurface else { return }
            // SAFETY: ``liveSurface`` on the lane: alive until close() fences the lane.
            unsafe feed(surface, data)
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
            unsafe ghostty_surface_process_output(surface, base, UInt(buffer.count))
        }
    }

    /// Restores GHOSTSNP bytes (`ghostty_surface_restore_snapshot`) in
    /// stream order. Counted as backlog like output, so history pages push
    /// back on the IO the same way. A failed READY leaves the terminal as it
    /// was (logged); a failed history chunk keeps the pages applied so far.
    func restoreSnapshot(_ data: Data, phase: ghostty_surface_snapshot_phase_e) {
        guard !data.isEmpty else { return }
        backlog.withLock { $0.bytes += data.count }
        queue.async { [self] in
            defer { parsed(data.count) }
            guard let surface = liveSurface else { return }
            let ready = phase == GHOSTTY_SURFACE_SNAPSHOT_READY
            guard ready || readyRestored.load(ordering: .relaxed) else { return }
            // SAFETY: ``liveSurface`` on the lane; Ghostty reads buffer.count bytes of `data`'s
            // storage, alive for the closure, and copies what it keeps.
            let restored = unsafe data.withUnsafeBytes { buffer -> Bool in
                // SAFETY: as above.
                guard let base = unsafe buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                // SAFETY: as above.
                return unsafe ghostty_surface_restore_snapshot(surface, base, buffer.count, phase)
            }
            if ready { readyRestored.store(restored, ordering: .releasing) }
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
    func restoreLocalHistory(_ data: Data, expectedRows: UInt64, digest: Data) {
        backlog.withLock { $0.bytes += data.count }
        queue.async { [self] in
            defer { parsed(data.count) }
            var result = Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_ERROR.rawValue)
            defer { localHistoryResult.store(result, ordering: .releasing) }
            guard let surface = liveSurface else { return }
            // SAFETY: ``liveSurface`` on the lane; Ghostty reads bytes.count bytes of `data` and
            // check.count of `digest`, both storages alive for the closures, and copies what it keeps.
            result = unsafe data.withUnsafeBytes { bytes -> Int32 in
                // SAFETY: as above.
                unsafe digest.withUnsafeBytes { check -> Int32 in
                    // SAFETY: as above.
                    guard let base = unsafe bytes.bindMemory(to: UInt8.self).baseAddress,
                          let expected = unsafe check.bindMemory(to: UInt8.self).baseAddress else {
                        return Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_ERROR.rawValue)
                    }
                    // SAFETY: as above.
                    return unsafe Int32(ghostty_surface_restore_snapshot_local_history(
                        surface, base, bytes.count, expectedRows, expected, check.count))
                }
            }
            // A local READY replaces the old one: no history chunk may follow it.
            readyRestored.store(false, ordering: .releasing)
            if result != Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_RESTORED.rawValue) {
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
        queue.async { [self] in
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

    /// Runs `body` on the lane with the live surface, or not at all after
    /// ``close()``.
    /// `body` must not keep the surface past its call.
    func perform(_ body: @escaping @Sendable (ghostty_surface_t) -> Void) {
        queue.async { [self] in
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
            queue.async { done.resume(returning: ()) }
        }
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
