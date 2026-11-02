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
///   the render waits on a detached task and the JPEG encode and write run on the files lane at best effort;
/// - bounded: one file per visible terminal; a terminal hidden or closed loses its file, and files of terminals this
///   run does not show are dropped once the launch read has ended (at most ``TerminalLaunchFrames/maximumFiles``).
///
/// A resize (a split, a window resize) or a file removed while hidden saves again as soon as the terminal is quiet,
/// with no ``interval``: the launch refuses a frame of another size, so an old one is as good as none.
/// Worst-case staleness at a kill: ``interval`` + ``busyWait`` + one encode while a terminal keeps changing (6 s and
/// the encode); after its last change, at most ``interval`` + ``idle`` (``idle`` when its last save is older). The
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

    private let directory: URL
    private let work: BackgroundWork
    private let clock: any Clock<Duration>
    /// Whether the launch read of the files has ended: files of terminals this run does not show are dropped only then.
    private let readEnded: @MainActor () -> Bool
    private var kept: [String: Kept] = [:]
    private var stopped = false
    /// Saves started, for tests and `debug.timings`.
    private(set) var saves = 0
    /// Files removed (a terminal hidden or closed, or one this run does not show).
    private(set) var removals = 0
    /// Runs on the files lane after each write or removal of a key's file (tests).
    var onWritten: (@Sendable (String) -> Void)?

    private struct Kept {
        weak var session: TerminalSession?
        let changes: TerminalFrameChanges
        let timer: DemandTimer
        /// The change count the last check saw.
        var seen: UInt64 = 0
        /// The last save's start.
        var lastSave: ContinuousClock.Instant?
        /// Since when a due save waits for the terminal to go quiet.
        var waitingSince: ContinuousClock.Instant?
        /// The terminal's size at the last save: a frame of another size is refused at launch, so a resize saves again
        /// without waiting for ``interval``.
        var savedSize: CGSize?
        var onDisk = false
    }

    init(directory: URL, work: BackgroundWork, clock: any Clock<Duration> = ContinuousClock(),
         readEnded: @escaping @MainActor () -> Bool) {
        self.directory = directory
        self.work = work
        self.clock = clock
        self.readEnded = readEnded
    }

    /// Keeps `session`'s frame under `key` from now on (again for a new session of the key). A first frame is saved
    /// ``idle`` after the call.
    func keep(_ key: String, session: TerminalSession) {
        guard !stopped, TerminalLaunchFrames.isFileSafe(key) else { return }
        if let old = kept[key], old.session === session { return }
        kept[key]?.timer.cancel()
        let changes = session.frameChanges
        kept[key] = Kept(session: session, changes: changes, timer: DemandTimer(owner: "terminal.launch-frames.keep-frame", clock: clock))
        changes.observe { [weak self] in
            // task-owner: one hop per first change after a check, never per output chunk (TerminalFrameChanges)
            Task { @MainActor [weak self] in self?.changed(key) }
        }
        changed(key)
    }

    /// The quit path saves every visible frame itself: no keeper save may land after it.
    func stop() {
        stopped = true
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
        // Not on screen (hidden, its workspace away, closed): its file goes at once, with no interval.
        guard let session = entry.session, Self.isOnScreen(session) else {
            _ = entry.changes.take()
            if entry.session == nil { kept[key] = nil }
            remove(key)
            return
        }
        // Laid out at no size for a moment (a split's layout pass): look again, keep the file.
        guard session.surfaceView.bounds.width > 0, session.surfaceView.bounds.height > 0 else {
            entry.timer.schedule(after: Self.idle) { @MainActor [weak self] in await self?.check(key) }
            return
        }
        let now = ContinuousClock.now
        let generation = entry.changes.generation
        let changedSinceCheck = generation != entry.seen
        entry.seen = generation
        // Nothing usable on disk (removed while hidden, or saved at another size): save as soon as it is quiet.
        let stale = !entry.onDisk || entry.savedSize != session.surfaceView.bounds.size
        if !stale, let last = entry.lastSave, now - last < Self.interval {
            kept[key] = entry
            entry.timer.schedule(after: Self.interval - (now - last)) { @MainActor [weak self] in await self?.check(key) }
            return
        }
        if changedSinceCheck, entry.lastSave != nil {
            let since = entry.waitingSince ?? now
            if now - since < Self.busyWait {
                entry.waitingSince = since
                kept[key] = entry
                entry.timer.schedule(after: Self.idle) { @MainActor [weak self] in await self?.check(key) }
                return
            }
        }
        // From here a new change tells the keeper again.
        let taken = entry.changes.take()
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
            kept[key]?.timer.schedule(after: Self.idle) { @MainActor [weak self] in await self?.check(key) }
            return
        }
        let size = session.surfaceView.bounds.size
        saves += 1
        // The GPU copy starts on the main actor (the layer's IOSurface); the render waits off it.
        guard let frame = await session.snapshotInBackground(maxPixelSize: .greatestFiniteMagnitude), !stopped else { return }
        let scale = max(1, min(3, Int((CGFloat(frame.width) / size.width).rounded())))
        let directory = directory, prune = readEnded() ? Set(kept.keys) : nil
        kept[key]?.onDisk = true
        kept[key]?.savedSize = size
        // Posted, not awaited: nothing waits for it, so it stays at best effort (BackgroundWork, priority inversion).
        let written = onWritten
        work.post(.bestEffort, mayBlock: .files) {
            TerminalLaunchFrames.writeOne(frame, key: key, scale: scale, to: directory, keeping: prune)
            written?(key)
        }
    }

    private static func isOnScreen(_ session: TerminalSession) -> Bool {
        !session.isRenderingSuspended && session.surfaceView.window?.isVisible == true
            && !session.surfaceView.isHiddenOrHasHiddenAncestor
    }

    private func remove(_ key: String) {
        guard kept[key]?.onDisk ?? true else { return }
        if kept[key] != nil { kept[key]?.onDisk = false }
        removals += 1
        let directory = directory
        let written = onWritten
        work.post(.bestEffort, mayBlock: .files) {
            TerminalLaunchFrames.removeAll(of: key, in: directory)
            written?(key)
        }
    }
}
