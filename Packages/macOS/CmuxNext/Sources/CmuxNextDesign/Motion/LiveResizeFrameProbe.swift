#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesignTokens
import CmuxNextWakeups

/// Times each frame of a window's live resize while `debug.motion` records (FRAME OWNER REFACTOR S7; DEBUG and bench
/// builds), with `motion.frameOwner.liveResize` on or off, so a film's late frames can be split by cause. One
/// ``LiveResizeDragInput`` owns one. Per `setFrame` of the resize, ``MotionTrace`` samples (`samples` of
/// `debug.motion stop`, `t_ms` from `start`):
/// - `liveResize.wait_ms`: from the drag's event time to the start of the `setFrame` that applies it (a drag that waited
///   for a frame tick shows the wait);
/// - `liveResize.at_tick`: 1 when a frame tick gave AppKit the drag, 0 when it went in its own turn;
/// - `liveResize.lead_ms`: from the `setFrame`'s start to the first display time after it (the window's display link
///   target, only while that link ran in the last ``linkFreshness``);
/// - `liveResize.setFrame_ms`: the `setFrame`: AppKit's resize, the tree layout and what AppKit flushes inside it
///   (`lead_ms` minus this is the slack at its end). The probe's own reads before it (the edge probe, the page window
///   step) are outside this clock, and `wait_ms` and `lead_ms` count from where it starts;
/// - `liveResize.commit_slack_ms`: from the end of the turn's Core Animation commit (an observer one order after it)
///   to that display time; below 0 the turn's commit came after it, and what the commit carried showed a refresh late;
/// - `liveResize.layouts_inside`: window layout passes (`-[NSWindow layoutIfNeeded]`, any window) begun inside the
///   `setFrame` (AppKit's own tree layout there is not one). Above 0, the overlay's held page update can go out before
///   the window's didResize, and the drag posts twice (Codex review of f9c15782c94);
/// - `liveResize.commit_inside`: 1 when a Core Animation commit happened inside the `setFrame` (AppKit flushed the new
///   size there: what S7 sends when the `setFrame` returns misses that commit), else 0 (``CommitWitness``);
/// - `liveResize.commit_before_didresize`: 1 when that commit happened before the window's didResize inside the
///   `setFrame`, 0 when after it; -1 when no didResize came inside the `setFrame`;
/// - `liveResize.view_layouts_inside`: `-[NSView layout]` calls (any window) inside the `setFrame`;
/// - `liveResize.view_layouts_after`: those calls from the `setFrame`'s end to the end of the turn's commit (what the
///   turn still laid out after a commit inside the `setFrame` shows one commit later);
/// - `liveResize.after_ms`: from the `setFrame`'s end to the end of the turn's commit;
/// - `liveResize.content_views`, `liveResize.view_edge_err_pt`, `liveResize.layer_edge_err_pt`: just before the turn's
///   commit, the pane contents measured and their largest left or right edge distance from their pane content area,
///   from view frames and from model layers (``ContentEdgeProbe``); `..._before` the same at the drag's start (the state
///   the last commit sent: the baseline);
/// - `liveResize.pane_edge_err_pt` / `pane_layer_edge_err_pt` (against the pane's clip view, the edge a film measures),
///   `strip_edge_err_pt` / `strip_layer_edge_err_pt` (left edge against the pane's tab strip), with `..._before`;
///   `liveResize.pixel_lag_px` (a terminal's shown IOSurface against its layer's size) and `liveResize.page_window_err_pt`
///   (each shown page window against the page host nearest it, all edges), both just before the commit;
/// - `liveResize.witness_ok`: 1 when the turn's commit showed in the witness (its `commit_inside` readings are valid), 0
///   when even the turn's commit did not (they mean nothing);
/// - which call moves a page window (``PageWindowMoves``; while a page window shows): the largest edge change of any shown
///   page window, in points, `liveResize.page_moved_before_setframe_pt` from the last step to this `setFrame`'s start
///   (between turns, or in this turn before the `setFrame`); inside the `setFrame`, `..._before_didresize_pt` up to the
///   window delegate's didResize and `..._from_didresize_pt` from it to the `setFrame`'s end (the fork's tracker also
///   observes didResize: its move there counts in one of the two, by the observers' order), `..._in_setframe_pt` the larger of those;
///   `..._at_release_pt` when the held frame notices go; `..._at_page_post_pt` the overlay's page update after the
///   `setFrame`; `..._after_setframe_pt` from there to just before the turn's commit;
/// - `liveResize.didresize_at_ms` (the `setFrame`'s start to its didResize) and `liveResize.after_didresize_ms` (from
///   there to the `setFrame`'s end: the fork's tracker moves the page window and Chromium resizes its page in it);
/// - `liveResize.didmove_at_ms` (the `setFrame`'s start to the window delegate's didMove), `liveResize.didmove_first` (1
///   when it came before the didResize, 0 after it) and `liveResize.page_moved_before_didmove_pt` (a page window's move
///   from the last checkpoint to it: the fork's tracker also observes didMove, after the delegate);
/// - `liveResize.commit_ms`: the turn's Core Animation commit (Chromium's pre- and post-commit resize waits run in it);
///   `liveResize.page_move_to_commit_ms`: from the turn's first step that saw a page window move to the commit's end;
/// - only with `motion.frameOwner.liveResize.windowServerProbe` on (default off: each read is a window server round trip
///   of 7-9 ms that changed what the films show, ab-s7pm2-24): whether a move reached the window server before the turn's
///   commit or with it, from the window server's frames read
///   just before and just after each commit of the resize (by window; compared only with each other): just before it,
///   `liveResize.window_step_pt` / `page_step_pt` (how far AppKit moved the window and its page windows since the last
///   read) and `liveResize.ws_window_moved_before_commit_pt` / `ws_page_moved_before_commit_pt` (how far the window
///   server's frames moved then: about the step, to within 4 pt, when the move reached it ahead of the commit, 0 when
///   not; on a fleet display its frame is AppKit's inset by 2-4 pt, and the inset changes between reads); just after it,
///   `liveResize.ws_window_moved_in_commit_pt` / `ws_page_moved_in_commit_pt` (how far they moved across the commit: the
///   step when the commit took it there); `liveResize.ws_query_ms` the read's time before the commit (it delays the
///   commit by that much).
@MainActor
final class LiveResizeFrameProbe {
    /// A `setFrame` of the resize: when it started and the display time it can first make (nil: no recent display link).
    struct Frame {
        let start: CFTimeInterval
        let target: CFTimeInterval?
        /// ``LayoutPassGuard/windowLayoutsBegun`` when the `setFrame` started.
        let layoutsBegun: Int
        /// ``LayoutPassGuard/viewLayoutCalls`` when the `setFrame` started.
        let viewLayouts: Int
    }

    /// How old the window's last display-link frame may be for its target to place a `setFrame` on the refresh.
    static let linkFreshness: CFTimeInterval = 0.1

    /// The display times of the frames applied since the last commit.
    private var awaitingCommit: [CFTimeInterval] = []
    /// When the last applied `setFrame` ended and ``LayoutPassGuard/viewLayoutCalls`` then (nil: none since the commit).
    private var lastApplied: (end: CFTimeInterval, viewLayouts: Int)?
    private let witness = CommitWitness()
    /// Whether a commit happened before the window's didResize in the `setFrame` running now (nil: no didResize yet).
    private var committedBeforeResize: Bool?
    /// A probed `setFrame` runs now.
    private var applying = false
    /// The turn's end: just before its commit and just after it.
    private lazy var turn = CommitTurnObservers(beforeCommit: { [weak self] in self?.contentEdgesBeforeCommit() },
                                                afterCommit: { [weak self] in self?.commitDidEnd() })
    private weak var window: NSWindow?
    private let edges = ContentEdgeProbe()
    private var pageMoves = PageWindowMoves()
    /// This `setFrame`'s start, its didResize and didMove (nil: none yet) and the largest page window move seen inside it.
    private var applyStart: CFTimeInterval = 0
    private var didResizeAt: CFTimeInterval?
    private var didMoveAt: CFTimeInterval?
    private var movedInSetFrame: CGFloat?
    /// The turn's first step that saw a page window move, and its commit's start (nil: none yet).
    private var firstPageMove: CFTimeInterval?
    private var commitStart: CFTimeInterval?
    /// The last read of the window server's frames and AppKit's, by window number (nil: none in this resize yet).
    private var lastServerRead: (time: CFTimeInterval, server: [Int: CGRect], appKit: [Int: CGRect])?

    /// A `setFrame` of the live resize starts in `window`; nil unless `debug.motion` records. `eventTime`: the drag
    /// AppKit applies (`NSEvent.timestamp`); `atTick`: a frame tick gave it.
    func frameWillApply(in window: NSWindow, eventTime: TimeInterval?, atTick: Bool) -> Frame? {
        guard MotionTrace.isEnabled else { return nil }
        self.window = window
        // The probe's own reads go before the `setFrame`'s clock starts (the edge probe walks the window's tree).
        let measured = edges.measure(in: window)
        pageStep("liveResize.page_moved_before_setframe_pt", in: window, at: CACurrentMediaTime(), notes: false)
        if let root = window.contentView?.layer { witness.attach(to: root) }
        witness.arm()
        let start = CACurrentMediaTime()
        let tick = FrameScheduler.forWindow(window).lastTick
        let target = tick.flatMap { tick in tick.refreshInterval.flatMap { Self.target(after: start, frameTarget: tick.targetTimestamp, interval: $0) } }
        if let eventTime { MotionTrace.sample("liveResize.wait_ms", (start - eventTime) * 1000) }
        MotionTrace.sample("liveResize.at_tick", atTick ? 1 : 0)
        if let target { MotionTrace.sample("liveResize.lead_ms", (target - start) * 1000) }
        if let measured {
            MotionTrace.sample("liveResize.view_edge_err_pt_before", measured.area)
            MotionTrace.sample("liveResize.layer_edge_err_pt_before", measured.areaLayer)
            MotionTrace.sample("liveResize.pane_edge_err_pt_before", measured.pane)
            MotionTrace.sample("liveResize.strip_edge_err_pt_before", measured.strip)
        }
        (applyStart, didResizeAt, didMoveAt, movedInSetFrame) = (start, nil, nil, nil)
        (committedBeforeResize, applying) = (nil, true)
        return Frame(start: start, target: target, layoutsBegun: LayoutPassGuard.shared.windowLayoutsBegun,
                     viewLayouts: LayoutPassGuard.shared.viewLayoutCalls)
    }

    /// The window's didResize (its delegate's, synchronous on the main thread): inside a `setFrame` of the resize, whether
    /// a commit already happened.
    func windowDidResize() {
        guard applying, committedBeforeResize == nil else { return }
        committedBeforeResize = witness.committed
        let now = CACurrentMediaTime()
        didResizeAt = now
        if let window { noteInSetFrame(pageStep("liveResize.page_moved_before_didresize_pt", in: window, at: now)) }
    }

    /// The window's didMove (its delegate's, synchronous on the main thread): inside a `setFrame` of the resize, when it
    /// came and whether before the didResize, and how far a page window moved since the last checkpoint.
    func windowDidMove() {
        guard applying, didMoveAt == nil, let window else { return }
        let now = CACurrentMediaTime()
        didMoveAt = now
        MotionTrace.sample("liveResize.didmove_at_ms", (now - applyStart) * 1000)
        MotionTrace.sample("liveResize.didmove_first", didResizeAt == nil ? 1 : 0)
        noteInSetFrame(pageStep("liveResize.page_moved_before_didmove_pt", in: window, at: now))
    }

    /// `super.setFrame` returned, before the held frame notices go: the page windows' moves inside it.
    func setFrameDidReturn() {
        guard applying, let window else { return }
        let now = CACurrentMediaTime()
        noteInSetFrame(pageStep(didResizeAt == nil ? nil : "liveResize.page_moved_from_didresize_pt", in: window, at: now))
        if let movedInSetFrame { MotionTrace.sample("liveResize.page_moved_in_setframe_pt", movedInSetFrame) }
        if let didResizeAt {
            MotionTrace.sample("liveResize.didresize_at_ms", (didResizeAt - applyStart) * 1000)
            MotionTrace.sample("liveResize.after_didresize_ms", (now - didResizeAt) * 1000)
        }
    }

    /// The overlay's held page update went (the input's `frameApplied`): the page windows' moves it made.
    func pageUpdatePosted() {
        guard lastApplied != nil, let window else { return }
        pageStep("liveResize.page_moved_at_page_post_pt", in: window, at: CACurrentMediaTime())
    }

    /// That `setFrame` returned: its time now, its commit's when the turn commits.
    func frameDidApply(_ frame: Frame) {
        MotionTrace.sample("liveResize.setFrame_ms", (CACurrentMediaTime() - frame.start) * 1000)
        MotionTrace.sample("liveResize.layouts_inside", Double(LayoutPassGuard.shared.windowLayoutsBegun - frame.layoutsBegun))
        applying = false
        if let window { pageStep("liveResize.page_moved_at_release_pt", in: window, at: CACurrentMediaTime()) }
        MotionTrace.sample("liveResize.commit_inside", witness.committed ? 1 : 0)
        MotionTrace.sample("liveResize.commit_before_didresize", committedBeforeResize.map { $0 ? 1 : 0 } ?? -1)
        let viewLayouts = LayoutPassGuard.shared.viewLayoutCalls
        MotionTrace.sample("liveResize.view_layouts_inside", Double(viewLayouts - frame.viewLayouts))
        lastApplied = (CACurrentMediaTime(), viewLayouts)
        if let target = frame.target { awaitingCommit.append(target) }
        turn.arm()
    }

    private func contentEdgesBeforeCommit() {
        guard let window else { return }
        defer {
            pageStep("liveResize.page_moved_after_setframe_pt", in: window, at: CACurrentMediaTime())
            sampleWindowServerMoves(in: window, afterCommit: false)
            commitStart = CACurrentMediaTime()
        }
        guard let measured = edges.measure(in: window) else { return }
        MotionTrace.sample("liveResize.content_views", Double(measured.views))
        MotionTrace.sample("liveResize.view_edge_err_pt", measured.area)
        MotionTrace.sample("liveResize.layer_edge_err_pt", measured.areaLayer)
        MotionTrace.sample("liveResize.pane_edge_err_pt", measured.pane)
        MotionTrace.sample("liveResize.pane_layer_edge_err_pt", measured.paneLayer)
        MotionTrace.sample("liveResize.strip_edge_err_pt", measured.strip)
        MotionTrace.sample("liveResize.strip_layer_edge_err_pt", measured.stripLayer)
        MotionTrace.sample("liveResize.pixel_lag_px", measured.pixelLag)
        MotionTrace.sample("liveResize.page_window_err_pt", measured.pageWindow)
    }

    private func commitDidEnd() {
        let end = CACurrentMediaTime()
        for target in awaitingCommit { MotionTrace.sample("liveResize.commit_slack_ms", (target - end) * 1000) }
        awaitingCommit.removeAll()
        if let lastApplied {
            MotionTrace.sample("liveResize.view_layouts_after", Double(LayoutPassGuard.shared.viewLayoutCalls - lastApplied.viewLayouts))
            MotionTrace.sample("liveResize.after_ms", (end - lastApplied.end) * 1000)
            // The turn's commit carried the witness's value: 1 proves `commit_inside` can see a commit in this window.
            MotionTrace.sample("liveResize.witness_ok", witness.committed ? 1 : 0)
        }
        if let commitStart { MotionTrace.sample("liveResize.commit_ms", (end - commitStart) * 1000) }
        if let firstPageMove { MotionTrace.sample("liveResize.page_move_to_commit_ms", (end - firstPageMove) * 1000) }
        let probed = lastApplied != nil
        (lastApplied, commitStart, firstPageMove) = (nil, nil, nil)
        if probed, let window { sampleWindowServerMoves(in: window, afterCommit: true) }
    }

    /// A step of the page windows (``PageWindowMoves``): samples `name` (when given) with the largest move since the last
    /// step and, unless `notes` is false, keeps the turn's first move. Nil when no page window shows.
    @discardableResult
    private func pageStep(_ name: String?, in window: NSWindow, at time: CFTimeInterval, notes: Bool = true) -> CGFloat? {
        guard let moved = pageMoves.step(in: window, at: time) else { return nil }
        if let name { MotionTrace.sample(name, moved) }
        if notes, moved > 0, firstPageMove == nil { firstPageMove = time }
        return moved
    }

    private func noteInSetFrame(_ moved: CGFloat?) {
        guard let moved else { return }
        movedInSetFrame = max(movedInSetFrame ?? 0, moved)
    }

    /// Reads the window server's frames of the window and its page windows, and samples how far they and AppKit's moved
    /// since the last read (`ws_*_moved_*_pt`, `window_step_pt`, `page_step_pt`); before the commit, also the read's time.
    private func sampleWindowServerMoves(in window: NSWindow, afterCommit: Bool) {
        guard MotionTunables.frameOwnerLiveResizeWindowServerProbe.value else { return }
        let start = CACurrentMediaTime()
        let server = PageWindowMoves.windowServerFrames(of: window)
        let now = CACurrentMediaTime()
        if !afterCommit { MotionTrace.sample("liveResize.ws_query_ms", (now - start) * 1000) }
        let appKit = PageWindowMoves.appKitFrames(of: window)
        defer { lastServerRead = (now, server, appKit) }
        guard let last = lastServerRead, now - last.time <= PageWindowMoves.freshness else { return }
        let main = window.windowNumber
        let pages = server.keys.filter { $0 != main }
        let when = afterCommit ? "in_commit" : "before_commit"
        if !afterCommit {
            if let step = PageWindowMoves.largestMove(from: last.appKit, to: appKit, of: [main]) { MotionTrace.sample("liveResize.window_step_pt", step) }
            if let step = PageWindowMoves.largestMove(from: last.appKit, to: appKit, of: pages) { MotionTrace.sample("liveResize.page_step_pt", step) }
        }
        if let moved = PageWindowMoves.largestMove(from: last.server, to: server, of: [main]) {
            MotionTrace.sample("liveResize.ws_window_moved_\(when)_pt", moved)
        }
        if let moved = PageWindowMoves.largestMove(from: last.server, to: server, of: pages) {
            MotionTrace.sample("liveResize.ws_page_moved_\(when)_pt", moved)
        }
    }

    /// The first display time at or after `time` on a display link whose last frame shows at `frameTarget`, one refresh
    /// every `interval` seconds; nil when that frame is older than ``linkFreshness`` or `interval` is not a period. A
    /// synthesized frame (no refresh period) places nothing: the caller passes none.
    static func target(after time: CFTimeInterval, frameTarget: CFTimeInterval, interval: Double) -> CFTimeInterval? {
        guard interval > 0, interval.isFinite, time - frameTarget < linkFreshness else { return nil }
        guard time > frameTarget else { return frameTarget }
        return frameTarget + ((time - frameTarget) / interval).rounded(.up) * interval
    }
}
#endif
