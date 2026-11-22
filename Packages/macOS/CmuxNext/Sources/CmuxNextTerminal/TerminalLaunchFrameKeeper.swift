public import AppKit
public import CmuxNextWakeups

/// REOPEN-F6 (reopen film, 2026-11-02): the terminals' last frames were saved only when the app quit
/// (``TerminalLaunchFrames/save(_:)``), so after a kill (a crash, a force quit, a power loss) no visible terminal had a
/// frame and every pane was empty until its live content, 566-730 ms after main(). The keeper keeps each visible
/// terminal's frame on disk while the app runs, in the same files the launch reads (``TerminalLaunchFrames``):
///
/// - only after a change of the terminal (``TerminalFrameChanges``: its output, a replay, a resize, shown or hidden),
///   never per keystroke: ``idle`` after the change, and at most once per ``interval`` per terminal;
/// - off the main thread: the main actor only starts the GPU copy of the presented frame (as hover previews do);
///   the render waits on a detached task, the encode runs on the CPU lane and the write on the files lane, at best
///   effort (``TerminalLaunchFrameWriter``);
/// - as deltas: a frame with the pixels already on disk is not encoded again, and a terminal shown again with the
///   pixels it was hidden with gets its parked file back by a rename (``TerminalLaunchFrameWriter``);
/// - bounded: one file per visible terminal; a terminal hidden loses its file (parked: no launch reads it) and one
///   closed loses both, and files of terminals this run does not show are dropped once the launch read has ended (at
///   most ``TerminalLaunchFrames/maximumFiles``); a pane that still shows its saved frame ahead of its surface shows
///   that terminal (#32274).
///
/// A resize (a split, a window resize) or a file removed while hidden saves again as soon as the terminal is quiet,
/// with no ``interval``: the launch refuses a frame of another size, so an old one is as good as none.
/// Worst-case staleness at a kill: ``interval`` + ``busyWait`` + one encode while a terminal starts changing (6 s and
/// the encode), backing off to ``busiestInterval`` + ``busyWait`` while it keeps changing
/// (``interval(afterBusySaves:)``); after its last change, at most the interval it reached + ``idle``. The
/// quit path still saves every visible frame fresh (and stops the keeper first).
/// It keeps the app's rendered frame for the window's first frame only; the text itself is the daemon's.
@MainActor
final class TerminalLaunchFrameKeeper {
    /// How long a terminal stays unchanged before its frame is saved.
    nonisolated static let idle: Duration = .milliseconds(500)
    /// The shortest time between two saves of one terminal (a busy terminal saves at most this often).
    nonisolated static let interval: Duration = .seconds(5)
    /// How long a due save waits for a still-changing terminal to go quiet before it saves anyway.
    nonisolated static let busyWait: Duration = .seconds(1)
    /// The longest time between two saves of a terminal that never goes quiet (an agent streaming in it).
    nonisolated static let busiestInterval: Duration = .seconds(60)

    /// The time between saves after `streak` saves in a row taken while the terminal was still changing: ``interval``,
    /// doubled per such save up to ``busiestInterval``. A save taken quiet ends the streak.
    ///
    /// Leo's NIGHTLY, 2026-11-21 (load 164-228 on 15 cores): the CPU lane encoded a 4642 x 2576 px PNG (46-57 ms) about
    /// once a second, every visible terminal that kept printing saved again each ``interval`` + ``busyWait``, and its
    /// pixels had always changed. A terminal that keeps changing has no settled frame to keep: its saves now back off
    /// (saves 6 s apart, then 11, 21, 41, and every 61 s), and its first quiet check saves the frame that stays.
    nonisolated static func interval(afterBusySaves streak: Int) -> Duration {
        guard streak > 0 else { return interval }
        let doubled = interval * (1 << min(streak, 4))
        return doubled < busiestInterval ? doubled : busiestInterval
    }

    /// Encodes and writes the frames as deltas, latest wins per terminal.
    private let writer: TerminalLaunchFrameWriter
    /// One clock for the timers' sleeps and the interval math: the continuous clock.
    private let started: ContinuousClock.Instant = .now
    private var now: Duration { started.duration(to: .now) }
    /// Checks of a shown terminal that has drawn nothing yet (a held launch frame, an attach that never came):
    /// a few, then the next change of the terminal wakes the keeper (no polling while idle).
    private var notDrawnChecks: [String: Int] = [:]
    nonisolated static let notDrawnRetries = 4
    /// Set by ``stop()``: a write already posted to the files lane checks it and drops (the quit writes after it).
    private let stopFlag: TerminalFrameChanges
    /// Whether the launch read of the files has ended: files of terminals this run does not show are dropped only then.
    private let readEnded: @MainActor () -> Bool
    /// The terminals whose saved frame a pane shows ahead of their surface (#32274): on screen, so never dropped.
    private let shownAhead: @MainActor () -> Set<String>
    private var kept: [String: Kept] = [:]
    private var stopped = false
    /// Saves started, for tests and `debug.timings`.
    private(set) var saves = 0
    /// Files removed (a terminal hidden or closed, or one this run does not show).
    private(set) var removals = 0
    /// Checks run on the main actor (each one a timer wake): tests count the ones a hidden terminal costs.
    private(set) var checks = 0
    /// Runs on the files lane after each write or removal of a key's file (tests).
    var onWritten: (@Sendable (String) -> Void)?

    private struct Kept {
        weak var session: TerminalSession?
        let changes: TerminalFrameChanges
        let timer: DemandTimer
        /// The change count the last check saw.
        var seen: UInt64 = 0
        /// The last save's start.
        var lastSave: Duration?
        /// Since when a due save waits for the terminal to go quiet.
        var waitingSince: Duration?
        /// The terminal's size at the last save: a frame of another size is refused at launch, so a resize saves again
        /// without waiting for ``interval``.
        var savedSize: CGSize?
        /// The size the previous check saw: a size still changing (a drag, a spring) waits for quiet.
        var seenSize: CGSize?
        var onDisk = false
        /// Saves in a row taken while the terminal was still changing (``interval(afterBusySaves:)``).
        var busySaves = 0
    }

    init(directory: URL, work: BackgroundWork,
         readEnded: @escaping @MainActor () -> Bool,
         shownAhead: @escaping @MainActor () -> Set<String> = { [] }) {
        let stopped = TerminalFrameChanges()
        stopFlag = stopped
        writer = TerminalLaunchFrameWriter(directory: directory, work: work, stillWanted: { stopped.generation == 0 })
        self.readEnded = readEnded
        self.shownAhead = shownAhead
    }

    /// Keeps `session`'s frame under `key` from now on (again for a new session of the key). A first frame is saved
    /// ``idle`` after the call.
    func keep(_ key: String, session: TerminalSession) {
        guard !stopped, TerminalLaunchFrames.isFileSafe(key) else { return }
        if let old = kept[key], old.session === session { return }
        kept[key]?.timer.cancel()
        notDrawnChecks[key] = nil
        let changes = session.frameChanges
        kept[key] = Kept(session: session, changes: changes, timer: DemandTimer(owner: "terminal.launch-frames.keep-frame", clock: ContinuousClock()))
        changes.observe { [weak self] in
            // task-owner: one hop per first change after a check, never per output chunk (TerminalFrameChanges)
            Task { @MainActor [weak self] in self?.changed(key) }
        }
        changed(key)
    }

    /// The size of `key`'s last save (tests).
    func savedSize(_ key: String) -> CGSize? { kept[key]?.savedSize }

    /// What the writer did so far: frames encoded, saves of unchanged pixels, parked files restored (tests, the bench).
    var writes: TerminalLaunchFrameWriter.Stats { writer.stats }
    /// The writer's jobs on the files and CPU lanes and their thread CPU time (the keeper bench).
    var laneCost: (files: LaneCost, cpu: LaneCost) { (writer.filesLane.total, writer.cpuLane.total) }

    /// The quit path saves every visible frame itself: no keeper save may land after it.
    func stop() {
        stopped = true
        stopFlag.bump()
        for entry in kept.values { entry.timer.cancel() }
        kept.removeAll()
    }

    /// A terminal changed: check it ``idle`` from now (a check already pending stays).
    private func changed(_ key: String) {
        guard !stopped, let entry = kept[key] else { return }
        entry.timer.scheduleIfIdle(after: Self.idle) { @MainActor [weak self] in await self?.check(key) }
    }

    /// Saves the terminal's frame (the write is posted to the files lane): at most once per ``interval``, when it was
    /// quiet for ``idle`` (one still changing after ``busyWait`` of a due save saves anyway), else checks again later.
    func check(_ key: String) async { // perf-hot: 1ms launch-first-frame (one terminal's frame keep check)
        guard !stopped, var entry = kept[key] else { return }
        checks += 1
        // Not on screen (hidden, its workspace away, closed): its file goes at once, with no interval. No read of the
        // changes: output while hidden only counts (the model), with no hop or timer here; the next visibility change
        // (``TerminalFrameChanges/wake()``: shown, drawn, closed) wakes the keeper again (SWITCH FRAMES SF-5).
        guard let session = entry.session, Self.isOnScreen(session) else {
            let closed = entry.session?.isClosed ?? true
            remove(key, closed: closed)
            // Closed: nothing visits it again. One only out of a window for now (a move) stays: its next window wakes it.
            if closed {
                entry.timer.cancel()
                kept[key] = nil
                notDrawnChecks[key] = nil
            }
            return
        }
        // Laid out at no size for a moment (a split's layout pass): keep the file; its next size change wakes the keeper.
        guard session.surfaceView.bounds.width > 0, session.surfaceView.bounds.height > 0 else {
            _ = entry.changes.take()
            return
        }
        let now = now
        let generation = entry.changes.generation
        let changedSinceCheck = generation != entry.seen
        entry.seen = generation
        let size = session.surfaceView.bounds.size
        let sizeMoving = entry.seenSize != nil && entry.seenSize != size
        entry.seenSize = size
        if changedSinceCheck { notDrawnChecks[key] = nil } // a few checks per change, not per terminal
        // Nothing usable on disk (removed while hidden, or saved at another size): save as soon as it is quiet.
        let stale = !entry.onDisk || entry.savedSize != session.surfaceView.bounds.size
        let interval = Self.interval(afterBusySaves: entry.busySaves)
        if !stale, let last = entry.lastSave, now - last < interval {
            kept[key] = entry
            entry.timer.schedule(after: interval - (now - last)) { @MainActor [weak self] in await self?.check(key) }
            return
        }
        if changedSinceCheck, entry.lastSave != nil {
            // A size still changing since the last check (a window drag, a pane spring) waits with no busy-wait
            // force: a frame of an in-between size is refused at launch anyway. Once it holds, busy terminals save.
            let since = entry.waitingSince ?? now
            if sizeMoving || now - since < Self.busyWait {
                entry.waitingSince = since
                kept[key] = entry
                entry.timer.schedule(after: Self.idle) { @MainActor [weak self] in await self?.check(key) }
                return
            }
        }
        // From here a new change tells the keeper again.
        let taken = entry.changes.take()
        // Still changing (its busy wait ran out): the next save waits longer. Quiet, a resize or a first save: the streak ends.
        entry.busySaves = changedSinceCheck && !stale && entry.lastSave != nil ? entry.busySaves + 1 : 0
        entry.lastSave = now
        entry.waitingSince = nil
        kept[key] = entry
        await save(key, entry.session)
        if taken != generation { changed(key) } // a change in between
    }

    /// Writes the session's presented frame under `key` (off the main thread), once its own content has drawn.
    private func save(_ key: String, _ session: TerminalSession?) async {
        guard let session, Self.isOnScreen(session), session.surfaceView.bounds.width > 0 else { return }
        // Its own content drawn: never a blank surface over the saved frame, nor the held frame of the last quit.
        guard session.surfaceHasContent, !session.frameHold.isHolding else {
            kept[key]?.lastSave = nil
            // A hold ends up to 500 ms after its content is queued: look again a few times, then wait for the
            // terminal's next change (an attach that never draws costs no wakeups).
            let tries = notDrawnChecks[key, default: 0] + 1
            notDrawnChecks[key] = tries
            if tries <= Self.notDrawnRetries {
                kept[key]?.timer.schedule(after: Self.idle) { @MainActor [weak self] in await self?.check(key) }
            }
            return
        }
        notDrawnChecks[key] = nil
        let size = session.surfaceView.bounds.size
        saves += 1
        // The GPU copy starts on the main actor (the layer's IOSurface); the render waits off it.
        guard let frame = await session.snapshotInBackground(maxPixelSize: .greatestFiniteMagnitude), !stopped else { return }
        let scale = max(1, min(3, Int((CGFloat(frame.width) / size.width).rounded())))
        // Kept: the terminals kept here and the panes still showing their saved frame ahead of a surface (#32274).
        let prune = readEnded() ? Set(kept.keys).union(shownAhead()) : nil
        kept[key]?.onDisk = true
        kept[key]?.savedSize = size
        // Posted, not awaited: nothing waits for it, so it stays at best effort (BackgroundWork, priority inversion).
        writer.save(key, frame: frame, scale: scale, keeping: prune, written: onWritten)
    }

    /// The surface view's own rule, which also tells the keeper when its answer changes (``TerminalSurfaceView/updateOcclusion()``).
    private static func isOnScreen(_ session: TerminalSession) -> Bool { session.surfaceView.showsForLaunchFrame }

    /// Hidden: the key's file is parked (a show with the same pixels restores it). Closed: its files go, parked too.
    private func remove(_ key: String, closed: Bool) {
        let onDisk = kept[key]?.onDisk ?? true
        guard onDisk || closed else { return }
        if kept[key] != nil { kept[key]?.onDisk = false }
        if onDisk { removals += 1 }
        if closed { writer.forget(key, written: onWritten) } else { writer.park(key, written: onWritten) }
    }
}
