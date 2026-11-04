#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextCompat
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
///   (`lead_ms` minus this is the slack at its end);
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
/// - `liveResize.witness_ok`: 1 when the turn's commit showed in the witness (its `commit_inside` readings are valid), 0
///   when even the turn's commit did not (they mean nothing).
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
    /// One after Core Animation's commit observer (order 2,000,000), as ``MotionCommitProbe``'s.
    static let afterCommitOrder: CFIndex = 2_000_001

    /// The display times of the frames applied since the last commit.
    private var awaitingCommit: [CFTimeInterval] = []
    /// When the last applied `setFrame` ended and ``LayoutPassGuard/viewLayoutCalls`` then (nil: none since the commit).
    private var lastApplied: (end: CFTimeInterval, viewLayouts: Int)?
    private let witness = CommitWitness()
    /// Whether a commit happened before the window's didResize in the `setFrame` running now (nil: no didResize yet).
    private var committedBeforeResize: Bool?
    /// A probed `setFrame` runs now.
    private var applying = false
    private var observer: CFRunLoopObserver?
    /// One before Core Animation's commit observer: after AppKit's layout and display passes (``MotionCommitProbe``).
    static let beforeCommitOrder: CFIndex = 1_999_999
    private var beforeCommit: CFRunLoopObserver?
    private weak var window: NSWindow?
    private let edges = ContentEdgeProbe()

    /// A `setFrame` of the live resize starts in `window`; nil unless `debug.motion` records. `eventTime`: the drag
    /// AppKit applies (`NSEvent.timestamp`); `atTick`: a frame tick gave it.
    func frameWillApply(in window: NSWindow, eventTime: TimeInterval?, atTick: Bool) -> Frame? {
        guard MotionTrace.isEnabled else { return nil }
        let start = CACurrentMediaTime()
        let tick = FrameScheduler.forWindow(window).lastTick
        let target = tick.flatMap { tick in tick.refreshInterval.flatMap { Self.target(after: start, frameTarget: tick.targetTimestamp, interval: $0) } }
        if let eventTime { MotionTrace.sample("liveResize.wait_ms", (start - eventTime) * 1000) }
        MotionTrace.sample("liveResize.at_tick", atTick ? 1 : 0)
        if let target { MotionTrace.sample("liveResize.lead_ms", (target - start) * 1000) }
        self.window = window
        if let measured = edges.measure(in: window) {
            MotionTrace.sample("liveResize.view_edge_err_pt_before", measured.view)
            MotionTrace.sample("liveResize.layer_edge_err_pt_before", measured.layer)
        }
        if let root = window.contentView?.layer { witness.attach(to: root) }
        witness.arm()
        (committedBeforeResize, applying) = (nil, true)
        return Frame(start: start, target: target, layoutsBegun: LayoutPassGuard.shared.windowLayoutsBegun,
                     viewLayouts: LayoutPassGuard.shared.viewLayoutCalls)
    }

    /// The window's didResize (its delegate's, synchronous on the main thread): inside a `setFrame` of the resize, whether
    /// a commit already happened.
    func windowDidResize() {
        guard applying, committedBeforeResize == nil else { return }
        committedBeforeResize = witness.committed
    }

    /// That `setFrame` returned: its time now, its commit's when the turn commits.
    func frameDidApply(_ frame: Frame) {
        MotionTrace.sample("liveResize.setFrame_ms", (CACurrentMediaTime() - frame.start) * 1000)
        MotionTrace.sample("liveResize.layouts_inside", Double(LayoutPassGuard.shared.windowLayoutsBegun - frame.layoutsBegun))
        applying = false
        MotionTrace.sample("liveResize.commit_inside", witness.committed ? 1 : 0)
        MotionTrace.sample("liveResize.commit_before_didresize", committedBeforeResize.map { $0 ? 1 : 0 } ?? -1)
        let viewLayouts = LayoutPassGuard.shared.viewLayoutCalls
        MotionTrace.sample("liveResize.view_layouts_inside", Double(viewLayouts - frame.viewLayouts))
        lastApplied = (CACurrentMediaTime(), viewLayouts)
        if let target = frame.target { awaitingCommit.append(target) }
        if beforeCommit == nil {
            // One shot, as the after-commit observer: the turn's contents just before its commit.
            let before = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                            false, Self.beforeCommitOrder) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.contentEdgesBeforeCommit() } // main-proof: added to the main run loop only
            }
            if let before {
                beforeCommit = before
                CFRunLoopAddObserver(CFRunLoopGetMain(), before, .commonModes)
            }
        }
        guard observer == nil else { return }
        // One shot: the turn's commit ends just before it; the run loop drops it after it runs.
        let observer = MainRunLoopObserver.afterCommitObserver(activities: [.beforeWaiting, .exit], repeats: false,
                                                               order: Self.afterCommitOrder) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitDidEnd() } // main-proof: added to the main run loop only
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func contentEdgesBeforeCommit() {
        beforeCommit = nil
        guard let window, let measured = edges.measure(in: window) else { return }
        MotionTrace.sample("liveResize.content_views", Double(measured.views))
        MotionTrace.sample("liveResize.view_edge_err_pt", measured.view)
        MotionTrace.sample("liveResize.layer_edge_err_pt", measured.layer)
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
        lastApplied = nil
        observer = nil
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
