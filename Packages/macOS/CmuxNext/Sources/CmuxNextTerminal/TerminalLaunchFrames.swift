public import AppKit
public import CmuxNextDesign
public import CmuxNextWakeups
import CmuxNextCompat

/// The terminals' last frames, saved at quit and drawn over each terminal at launch until its live
/// content draws (launch-speed-first: "the first frame is never blank"). A terminal pane is held
/// clear for launch until its first live frame (`LaunchSettle`): about 150 ms on a capture mini
/// with the daemon running, seconds when it starts cold. One JPEG per tab, named with its scale, as
/// the agent pages' last pages are (`AgentPaneLaunchImages`); each is handed out once per launch. The
/// launch reads and decodes every frame off the main thread from its start (``prefetch(on:keep:mark:markAt:)``, in
/// the app's `main` before `NSApplication.run`): a pane shows its frame at once when the read has ended
/// (``LaunchRead``: no main-actor hop), never waiting for it; one shown before then stays held clear, as with
/// no frame, and gets its frame when the read ends if it has drawn nothing live by then.
///
/// REOPEN-F1 (reopen film, 2026-11-02): the app makes at most one new surface per display frame
/// (`ContentPresentationScheduler`), so at a reopen only the first terminal had its frame in the window's first
/// frame; the other visible terminals stayed clear until their surfaces came, 125-200 ms later. A pane that waits
/// for its surface shows its frame ahead of it (``showAhead(_:in:reveal:)``: one layer, no surface, the frame is
/// decoded already), and the surface takes the frame over when it comes. Each terminal's frame is recorded
/// apart (``launchPanes``); the launch is drawn when the last one is (``visibleTerminalsDrawn``), never the first.
@MainActor
public final class TerminalLaunchFrames {
    /// A larger file is not read.
    nonisolated static let maximumBytes = 16 * 1024 * 1024
    /// The most frames one launch reads (one per terminal on screen at the last quit).
    nonisolated static let maximumFiles = 64
    private static var stores: [URL: TerminalLaunchFrames] = [:]

    let directory: URL?
    /// Reads the saved frames.
    private let reader: LaunchFileReader
    /// Drops the read's frames after ``prefetch(on:keep:mark:markAt:)``'s `keep`.
    private let discard: DemandTimer
    /// The launch read of the saved frames, decoded, by tab key (``prefetch(on:keep:mark:markAt:)``); nil before it
    /// starts and once its frames are dropped.
    private var read: LaunchRead<[String: Frame]>?
    /// The frames handed out (each once per launch).
    private var taken: Set<String> = []
    /// Panes that asked while the read ran, by tab key: each gets its frame when the read ends.
    private var waiting: [String: Waiter] = [:]
    /// Records a launch mark.
    private var mark: @Sendable (String) -> Void = { _ in }
    /// Records a launch mark at a given time (``visibleTerminalsDrawn``: when the last pane showed, not when that was seen).
    private var markAt: @Sendable (String, Date) -> Void = { _, _ in }
    /// Whether the read's results were dropped (``prefetch(on:keep:mark:markAt:)`` then starts no new read).
    private var readDropped = false
    /// Keeps the visible terminals' frames on disk while the app runs (``keep(_:session:work:)``), for a launch after a kill.
    private var keeper: TerminalLaunchFrameKeeper?
    /// Frames shown ahead of their terminal's surface, by the pane content they show in (``showAhead(_:in:reveal:)``).
    private var ahead: [ObjectIdentifier: Ahead] = [:]
    /// The terminals the launch's first window frame shows, by tab key: when each asked for its frame and when it
    /// showed (``launchPanes``). Keys ask until ``closeLaunch()``.
    private var panes: [String: LaunchPane] = [:]
    /// False once the launch's first window frame committed: a later ask is a tab switch, not a launch pane.
    private var launchOpen = true
    /// Whether ``visibleTerminalsDrawn`` was marked.
    private var drawnMarked = false

    /// One terminal of the launch's first window frame: when it asked for its frame, when the frame showed, and
    /// why it did not (nil while it may still show).
    public struct LaunchPane: Sendable, Equatable {
        public let asked: Date
        public internal(set) var shown: Date?
        public internal(set) var missed: String?
    }

    /// A frame shown in a pane before its terminal's surface exists.
    private struct Ahead {
        let key: String
        let frame: Frame
        let view: NSView
        weak var content: NSView?
    }

    /// The launch mark of the last of the launch's terminals to show its frame (the reopen number: the max over the
    /// visible terminals, never the first).
    public nonisolated static let visibleTerminalsDrawn = "launch.visible_terminals_drawn"

    /// A saved frame, decoded, with its point size and scale.
    private nonisolated struct Frame: Sendable {
        let image: CGImage
        let size: NSSize
        let scale: Int
    }

    /// A pane that asked for its frame before the read ended.
    private struct Waiter {
        /// Nil: it asked ahead of its surface (``showAhead(_:in:reveal:)``).
        weak var session: TerminalSession?
        weak var content: NSView?
        let reveal: LaunchReveal
    }

    init(directory: URL?, reader: LaunchFileReader = LaunchFileReader(), clock: any Clock<Duration> = ContinuousClock()) {
        self.directory = directory
        self.reader = reader
        discard = DemandTimer(owner: "terminal.launch-frames.keep", clock: clock)
    }

    /// The frames kept in `state`, the app's state directory (beside its sidebar snapshot); one
    /// store per directory, so a frame taken at launch is not handed out again.
    public static func beside(_ state: URL?) -> TerminalLaunchFrames {
        guard let state else { return TerminalLaunchFrames(directory: nil) }
        if let store = stores[state] { return store }
        let store = TerminalLaunchFrames(directory: state.appending(path: "terminal-launch-frames", directoryHint: .isDirectory))
        stores[state] = store
        return store
    }

    /// Starts reading and decoding every saved frame on `work`'s files lane at once; a later call does nothing.
    ///
    /// - Parameters:
    ///   - work: The app's blocking-work lanes.
    ///   - keep: How long the frames no pane took stay in memory (decoded frames are large), from now.
    ///   - mark: Records the launch marks `terminal.launch_frames_read` (on the lane, when the frames are
    ///     decoded: a pane asking after that gets its frame), `terminal.launch_frame_missed` (a pane asked
    ///     before that) and `terminal.launch_frame_shown` (the FIRST terminal of the launch's first window frame
    ///     showed its frame; kept for older readers).
    ///   - markAt: Records ``visibleTerminalsDrawn`` at the time the LAST terminal of the launch's first window
    ///     frame showed its frame (the reopen number is the max over the visible terminals, never the first).
    /// - Returns: A task that ends once the read has ended and the panes that asked before have their frames
    ///   (tests await it).
    @discardableResult
    public func prefetch(on work: BackgroundWork, keep: Duration = .seconds(30),
                         mark: @escaping @Sendable (String) -> Void = { _ in },
                         markAt: @escaping @Sendable (String, Date) -> Void = { _, _ in }) -> Task<Void, Never>? {
        guard let directory, read == nil, !readDropped else { return nil }
        self.mark = mark
        self.markAt = markAt
        let reader = reader
        let read = LaunchRead(on: work) {
            let frames = Self.readAll(in: directory, reader)
            mark("terminal.launch_frames_read")
            return frames
        }
        self.read = read
        // A deadline: the frames no pane took by then are dropped (decoded frames are large).
        discard.schedule(after: keep) { @MainActor [weak self] in self?.dropRead() }
        // task-owner: shows the frames of the panes that asked before the read ended; ends then.
        return Task { [weak self] in
            _ = await read.finished()
            self?.showWaiting()
        }
    }

    /// Drops the read's results that no pane took.
    private func dropRead() {
        read = nil
        readDropped = true
        ahead = ahead.filter { $0.value.content != nil && $0.value.view.superview != nil }
    }

    /// The terminals of the launch's first window frame, by tab key: when each asked and when its frame showed.
    public var launchPanes: [String: LaunchPane] { panes }

    /// When the last terminal of the launch's first window frame showed its frame: nil while one has not (or none asked).
    public var lastLaunchPaneShown: Date? {
        guard !panes.isEmpty else { return nil }
        let shown = panes.values.compactMap(\.shown)
        return shown.count == panes.count ? shown.max() : nil
    }

    /// The launch's first window frame committed: the terminals that asked by now are the ones it shows.
    public func closeLaunch() {
        launchOpen = false
        markDrawnIfComplete()
    }

    /// The launch's first window frame committed, for every store that read frames (``closeLaunch()``).
    public static func closeLaunches() {
        for store in stores.values where store.read != nil || store.readDropped { store.closeLaunch() }
    }

    /// `debug.timings`' launch rows, as JSON: `panes` (each terminal of the launch's first window frame by tab key:
    /// `asked_ms`, `frame_shown_ms`, `missed`) and `max_ms` (the last of them to show its frame; null while one has
    /// not). Times in `milliseconds` (the app's launch-mark clock).
    public static func launchReport(_ milliseconds: (Date) -> Double) -> Data? {
        func round(_ date: Date) -> Double { (milliseconds(date) * 10).rounded() / 10 }
        var rows: [String: [String: Any]] = [:]
        var last: [Date?] = []
        for store in stores.values where !store.panes.isEmpty {
            for (key, pane) in store.panes {
                var row: [String: Any] = ["asked_ms": round(pane.asked)]
                if let shown = pane.shown { row["frame_shown_ms"] = round(shown) }
                if let missed = pane.missed { row["missed"] = missed }
                rows[key] = row
            }
            last.append(store.lastLaunchPaneShown)
        }
        let max: Any = last.isEmpty || last.contains(where: { $0 == nil }) ? NSNull() : round(last.compactMap { $0 }.max() ?? Date())
        return try? JSONSerialization.data(withJSONObject: ["panes": rows, "max_ms": max])
    }

    private func noteAsked(_ key: String) {
        guard launchOpen, panes[key] == nil else { return }
        panes[key] = LaunchPane(asked: Date())
    }

    private func noteShown(_ key: String) {
        // Once-only (the first frame shown), as before, for older readers; the launch number is ``visibleTerminalsDrawn``.
        mark("terminal.launch_frame_shown")
        guard var pane = panes[key], pane.shown == nil else { return }
        pane.shown = Date()
        pane.missed = nil
        panes[key] = pane
        markDrawnIfComplete()
    }

    /// The frame shown ahead in `content`, if it is still that view's (a view made at a freed one's address is not).
    private func aheadEntry(in content: NSView) -> Ahead? {
        guard let entry = ahead[ObjectIdentifier(content)] else { return nil }
        guard entry.content === content else {
            ahead[ObjectIdentifier(content)] = nil
            return nil
        }
        return entry
    }

    /// `content` shows something else now: an ask ahead of its surface made before the read ended is void.
    private func dropAheadWaiters(in content: NSView) {
        waiting = waiting.filter { $0.value.session != nil || ($0.value.content.map { $0 !== content } ?? false) }
    }

    /// Records why `key`'s frame did not show. A later `no_frame` never replaces a reason: that ask finds the frame
    /// taken by the earlier one, and `no_frame` would hide the cause (#32493: frames refused for their `size`). Any
    /// other later reason (`size`, `scale`, `live`) is the newer cause and replaces it.
    private func noteMissed(_ key: String, _ reason: String) {
        guard var pane = panes[key], pane.shown == nil, !(reason == "no_frame" && pane.missed != nil) else { return }
        pane.missed = reason
        panes[key] = pane
    }

    private func markDrawnIfComplete() {
        guard !launchOpen, !drawnMarked, let last = lastLaunchPaneShown else { return }
        drawnMarked = true
        markAt(Self.visibleTerminalsDrawn, last)
    }

    /// The panes that asked before the read ended get their frames, if they still show the terminal
    /// and it has drawn nothing live.
    private func showWaiting() {
        let waiters = waiting
        waiting = [:]
        for (key, waiter) in waiters {
            guard let content = waiter.content else { continue }
            if let session = waiter.session {
                guard session.view.isDescendant(of: content) else { continue }
                show(key, on: session, in: content, reveal: waiter.reveal)
            } else {
                // Asked ahead of its surface; a surface that came meanwhile asked for itself.
                guard aheadEntry(in: content) == nil, !taken.contains(key) else { continue }
                showAhead(key, in: content, reveal: waiter.reveal)
            }
        }
    }

    /// Shows `key`'s frame from the last quit in `content`, a visible pane's content held for launch, before the
    /// terminal's surface exists: the pane waits for its surface (one new surface per display frame), and its
    /// frame, decoded off the main thread already, is one layer. `content` shows at once with it; the surface
    /// takes the frame over when it comes (``show(_:on:in:reveal:)``), or ``withdrawAhead(in:)`` takes it away.
    /// Before the read ends it shows nothing and shows the frame when the read ends. Only a frame of the pane's
    /// size (once laid out) at the window's scale. Returns whether it showed one now.
    @discardableResult
    public func showAhead(_ key: String, in content: NSView, reveal: LaunchReveal = .shared) -> Bool { // perf-hot: 1ms launch-first-frame (each visible terminal at launch)
        guard let read else { return false }
        noteAsked(key)
        if let shown = aheadEntry(in: content) {
            if shown.key == key { return false }
            withdrawAhead(in: content)
        }
        guard let frames = read.value else {
            mark("terminal.launch_frame_missed")
            dropAheadWaiters(in: content) // an earlier ask of this pane (another tab) is void now
            if waiting[key] == nil { waiting[key] = Waiter(session: nil, content: content, reveal: reveal) }
            return false
        }
        guard let frame = frames[key], !taken.contains(key) else {
            noteMissed(key, "no_frame")
            return false
        }
        // The surface's size once the pane is laid out: the content less a legacy scroller's strip.
        let bounds = content.bounds.size
        if bounds != .zero {
            let width = TerminalHostView.surfaceWidth(hostWidth: bounds.width)
            guard abs(frame.size.width - width) < 1, abs(frame.size.height - bounds.height) < 1 else {
                noteMissed(key, "size")
                return false
            }
        }
        guard content.window.map({ abs(CGFloat(frame.scale) - $0.backingScaleFactor) < 0.01 }) ?? true else {
            noteMissed(key, "scale")
            return false
        }
        taken.insert(key)
        let view = LaunchFrameView(frame.image, scale: frame.scale, in: content.bounds)
        content.addSubview(view)
        ahead[ObjectIdentifier(content)] = Ahead(key: key, frame: frame, view: view, content: content)
        reveal.release(content)
        noteShown(key)
        return true
    }

    /// Takes away the frame shown ahead in `content` (its pane shows other content now).
    public func withdrawAhead(in content: NSView) {
        dropAheadWaiters(in: content)
        guard let shown = aheadEntry(in: content) else { return }
        ahead[ObjectIdentifier(content)] = nil
        shown.view.removeFromSuperview()
    }

    /// The terminals whose saved frame a pane on screen shows ahead of their surface (#32274), or will show when the
    /// launch read ends (it asked ahead before then): no session is shown there yet, so no quit snapshot or keeper save
    /// covers them, and their saved frame is the one the pane shows. On screen as the quit and the keeper count it.
    var keysShownAhead: Set<String> {
        func onScreen(_ content: NSView?) -> Bool {
            guard let content else { return false }
            return content.window?.isVisible == true && !content.isHiddenOrHasHiddenAncestor
        }
        let shown = ahead.values.filter { $0.view.superview === $0.content && onScreen($0.content) }.map(\.key)
        let asked = waiting.filter { $0.value.session == nil && onScreen($0.value.content) }.map(\.key)
        return Set(shown).union(asked)
    }

    /// Whether `content` shows a frame ahead of its terminal's surface (tests).
    func showsAhead(in content: NSView) -> Bool {
        aheadEntry(in: content).map { $0.view.superview === content } ?? false
    }

    /// Shows `key`'s frame from the last quit over `session` until its live content draws
    /// (``TerminalLaunchFrame``), and `content`, the pane content held for launch, at once with it
    /// (no fade: it is the frame the pane showed). Never waits: before the launch read ends it shows
    /// nothing (`content` stays held, as with no frame) and shows the frame when the read ends, if the
    /// terminal is still in `content` and has drawn nothing live. Only a frame of the terminal's size and
    /// the window's scale: another would move or scale when the live frame replaced it. Returns whether
    /// it showed one now.
    @discardableResult
    public func show(_ key: String, on session: TerminalSession, in content: NSView, reveal: LaunchReveal = .shared) -> Bool {
        // A frame shown ahead of this surface: the surface takes it over in this transaction (no frame between).
        dropAheadWaiters(in: content)
        let early = aheadEntry(in: content)
        ahead[ObjectIdentifier(content)] = nil
        early?.view.removeFromSuperview()
        let frame: Frame
        if let early, early.key == key {
            frame = early.frame
        } else {
            guard let read else { return false }
            noteAsked(key)
            guard let frames = read.value else {
                mark("terminal.launch_frame_missed")
                waiting[key] = Waiter(session: session, content: content, reveal: reveal)
                return false
            }
            guard let found = frames[key], taken.insert(key).inserted else {
                noteMissed(key, "no_frame")
                return false
            }
            frame = found
        }
        if let missed = takeOver(frame, on: session, in: content) {
            // Shown ahead at a size the surface does not have: the pane stays shown (its terminal's background until
            // its first frame), never held clear again: a clear frame after a shown one is a flash.
            noteMissed(key, missed)
            return false
        }
        reveal.release(content)
        noteShown(key)
        return true
    }

    /// Shows `frame` over `session` in `content` (the checks of ``show(_:on:in:reveal:)``); nil when it showed,
    /// else why not.
    private func takeOver(_ frame: Frame, on session: TerminalSession, in content: NSView) -> String? {
        // The surface's size in this pane: its own frame is a placeholder until the pane lays it out
        // (this transaction does anyway). A pane not laid out yet (zero) takes the launch snapshot's
        // size, which the frame was saved at.
        let laidOut = content.bounds.size != .zero
        if laidOut {
            session.view.frame = content.bounds
            session.view.layoutSubtreeIfNeeded()
        }
        let size = session.surfaceView.bounds.size
        guard !laidOut || (abs(frame.size.width - size.width) < 1 && abs(frame.size.height - size.height) < 1) else { return "size" }
        // The held frame draws at the window's scale: one saved on a screen of another scale would not fit.
        guard content.window.map({ abs(CGFloat(frame.scale) - $0.backingScaleFactor) < 0.01 }) ?? true else { return "scale" }
        guard TerminalLaunchFrame(frame.image).show(on: session) else { return "live" }
        return nil
    }

    /// Keeps `session`'s last frame on disk under `key` while the app runs (``TerminalLaunchFrameKeeper``), so a launch
    /// after a kill shows it too, not only one after a quit. Once per session; a new session of the key replaces it.
    public func keep(_ key: String, session: TerminalSession, work: BackgroundWork) {
        guard let directory else { return }
        if keeper == nil {
            keeper = TerminalLaunchFrameKeeper(directory: directory, work: work, readEnded: { [weak self] in
                guard let self else { return false }
                return self.readDropped || self.read?.value != nil || self.read == nil
            }, shownAhead: { [weak self] in self?.keysShownAhead ?? [] })
        }
        keeper?.keep(key, session: session)
    }

    /// Frames the keeper saved so far (tests, `debug.timings`).
    var keepSaves: Int { keeper?.saves ?? 0 }
    /// The keeper's checks so far (each a main-actor timer wake).
    var keepChecks: Int { keeper?.checks ?? 0 }
    /// The size of `key`'s last kept save (tests).
    func keepSavedSize(_ key: String) -> CGSize? { keeper?.savedSize(key) }

    /// Saves the frames of `sessions` on screen, by tab key, replacing the last quit's. A bare
    /// prompt too: it is what the pane showed. The keeper stops first: no save of its may land after these.
    ///
    /// Issue #32274 (3 of 20 STRESS reopens showed a visible pane empty): a terminal on screen with no new frame keeps
    /// the one saved for it. A pane that still shows its saved frame ahead of its surface (its surface had not come, or
    /// its session was not presented yet) has no frame to take here; its saved frame is exactly what it shows. A shown
    /// terminal whose snapshot gave nothing keeps the keeper's last frame. Only terminals no pane shows lose theirs.
    public func save(_ sessions: [String: TerminalSession]) async {
        keeper?.stop()
        var frames: [String: NSImage] = [:]
        var kept = keysShownAhead
        for key in kept { mark("quit.terminal_frame.\(key).ahead") }
        for (key, session) in sessions {
            guard !session.isRenderingSuspended else {
                mark("quit.terminal_frame.\(key).suspended")
                continue
            }
            let surface = session.surfaceView
            // Each shown terminal's outcome is a quit mark (`quit.terminal_frame.<key>.<outcome>`, issue #32274).
            let skipped = surface.window?.isVisible != true ? "not_visible"
                : surface.isHiddenOrHasHiddenAncestor ? "hidden" : surface.bounds.width > 0 ? nil : "no_width"
            if let skipped {
                mark("quit.terminal_frame.\(key).\(skipped)")
                continue
            }
            // What the pane shows: a terminal still held over its slow attach saves its held frame.
            guard let frame = await session.shownFrameInBackground(maxPixelSize: .greatestFiniteMagnitude) else {
                mark("quit.terminal_frame.\(key).no_snapshot")
                kept.insert(key) // on screen: its last kept frame beats none
                continue
            }
            mark("quit.terminal_frame.\(key).snapshot")
            frames[key] = NSImage(cgImage: frame, size: surface.bounds.size)
        }
        await save(images: frames, keeping: kept.subtracting(frames.keys))
        mark("quit.terminal_frames.written")
    }

    /// Replaces the saved frames with `images` (by tab key, at their point size); the files of the keys in `keeping`
    /// stay as they are (terminals on screen with no new frame).
    func save(images: [String: NSImage], keeping: Set<String> = []) async {
        guard let directory else { return }
        // NSImage stays on the main actor; the JPEG encode and the writes run detached.
        var frames: [String: CGImage] = [:]
        var keeping = keeping
        for (key, image) in images where Self.isFileSafe(key) {
            // On screen with no bitmap to save: its saved frame stays, as for a snapshot that gave nothing.
            guard image.size.width > 0, let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                keeping.insert(key)
                continue
            }
            frames["\(key)@\(max(1, min(3, Int((CGFloat(frame.width) / image.size.width).rounded()))))x.jpg"] = frame
        }
        await Task.detached { [keeping] in Self.write(frames, keeping: keeping, to: directory) }.value
    }

    /// Every saved frame in `directory`, decoded, with its point size and scale, by tab key (for each
    /// key the first scale a save may have written).
    private nonisolated static func readAll(in directory: URL, _ reader: LaunchFileReader) -> [String: Frame] {
        // Saved frames only, then the cap: files a killed write left (`<key>@1x.jpg.sb-<id>`) never take a slot.
        let names = Set(((try? FileManager.checked.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { owner(of: $0) != nil }.sorted().prefix(maximumFiles))
        var frames: [String: Frame] = [:]
        for scale in [2, 1, 3] {
            let suffix = "@\(scale)x.jpg"
            for name in names where name.hasSuffix(suffix) {
                let key = String(name.dropLast(suffix.count))
                guard frames[key] == nil, isFileSafe(key),
                      let frame = reader.image(at: directory.appending(path: name), maximumBytes: maximumBytes) else { continue }
                frames[key] = Frame(image: frame, size: NSSize(width: CGFloat(frame.width) / CGFloat(scale), height: CGFloat(frame.height) / CGFloat(scale)), scale: scale)
            }
        }
        return frames
    }

    private nonisolated static func write(_ frames: [String: CGImage], keeping: Set<String>, to directory: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for old in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where frames[old] == nil {
            guard !keeping.contains(owner(of: old) ?? old) else { continue }
            try? manager.removeItem(at: directory.appending(path: old))
        }
        for (name, frame) in frames {
            let url = directory.appending(path: name)
            guard let data = NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [.compressionFactor: 0.9]),
                  (try? data.write(to: url, options: [.atomic])) != nil else { continue }
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Writes one terminal's frame (the keeper), replacing the key's file at any scale; with `keeping`, also removes the
    /// frames of every key not in it (terminals this run does not show), once the launch read has ended. `stillWanted`
    /// is asked again after the encode and before the cleanup: a quit that stopped the keeper meanwhile writes every
    /// frame itself, so a write that started before it neither lands over those frames nor prunes them.
    nonisolated static func writeOne(_ frame: CGImage, key: String, scale: Int, to directory: URL, keeping: Set<String>?,
                                     stillWanted: () -> Bool = { true }) {
        let manager = FileManager.checked
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "\(key)@\(scale)x.jpg"
        let url = directory.appending(path: name)
        if let data = NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [.compressionFactor: 0.9]),
           stillWanted(),
           (try? data.blockingWrite(to: url, options: [.atomic])) != nil {
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        guard stillWanted() else { return }
        for old in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where old != name {
            // Only saved frames: another write's file before its rename (the quit's, beside this one) is left alone.
            guard let tab = owner(of: old), tab == key || keeping.map({ !$0.contains(tab) }) == true else { continue }
            try? manager.removeItem(at: directory.appending(path: old))
        }
    }

    /// Removes every saved frame of `key` (the keeper: a terminal hidden or closed).
    nonisolated static func removeAll(of key: String, in directory: URL) {
        let manager = FileManager.checked
        for old in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where owner(of: old) == key {
            try? manager.removeItem(at: directory.appending(path: old))
        }
    }

    /// The tab key of a saved frame (`<key>@<scale>x.jpg`, scale 1 to 3); nil for any other file, such as Foundation's
    /// atomic-write file beside one before its rename (`<key>@2x.jpg.sb-<id>`).
    nonisolated static func owner(of file: String) -> String? {
        guard file.hasSuffix("x.jpg"), let at = file.lastIndex(of: "@") else { return nil }
        let scale = file[file.index(after: at)..<file.index(file.endIndex, offsetBy: -"x.jpg".count)]
        guard scale.count == 1, let digit = scale.first, ("1"..."3").contains(digit) else { return nil }
        return String(file[..<at])
    }

    /// Tab keys are `tab_<hex>`; anything else never becomes a path.
    nonisolated static func isFileSafe(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 128 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

/// A terminal's frame from the last quit, in its pane before the surface exists: top-left at its point size, as
/// the surface draws it, and no clicks.
private final class LaunchFrameView: NSView {
    nonisolated override var wantsUpdateLayer: Bool { true }

    init(_ image: CGImage, scale: Int, in bounds: NSRect) {
        super.init(frame: bounds)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.contentsGravity = .topLeft
        layer?.contentsScale = CGFloat(scale)
        layer?.contents = image
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
