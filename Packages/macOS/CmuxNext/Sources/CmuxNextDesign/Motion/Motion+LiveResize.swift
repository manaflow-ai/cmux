public import AppKit

extension Motion {
    /// Some window is in a live resize (the user drags its edge or corner):
    /// movement snaps (`MotionPolicy.liveResize`), so pane frames, tab strips
    /// and the sidebar follow the edge every frame and nothing springs toward
    /// a size the next frame replaces (cx-sqj3h). Starts with the window's
    /// `willStartLiveResize` and ends with its `didEndLiveResize` (or its close).
    ///
    /// A full screen enter or exit counts too (fullscreen-lag): AppKit sets
    /// the final size at once and animates a snapshot to it, so content that
    /// springs toward a size only shows its in-between frames late.
    public static var isLiveResizing: Bool { liveResizeOverride ?? LiveResizeWindows.shared.isActive }

    /// Whether `window` is in a live resize or a full screen transition: the
    /// per-window form of ``isLiveResizing`` for views that ask about their
    /// own window (`NSView.inLiveResize` misses full screen transitions).
    /// A frame animation (``beginFrameAnimation(_:)``) does not count: the
    /// window really moves, so a hover card still follows its target, and no
    /// end notice would hit-test again when it lands.
    public static func isLiveResizing(_ window: NSWindow?) -> Bool {
        if let liveResizeOverride { return liveResizeOverride }
        guard let window else { return false }
        return window.inLiveResize || LiveResizeWindows.shared.isTransitioning(window)
    }

    /// AppKit starts animating `window`'s frame for cmux (a Zoom, the floating chat's fold): until
    /// the matching ``endFrameAnimation(_:)``, its content holds its resizes as in a full screen
    /// transition (``holdsContentResize(_:)``), so each terminal sends one grid, at the end.
    /// ``isLiveResizing(_:)`` stays false, and other windows' motion is unchanged. Calls nest: every begin needs one end
    /// (the animation's completion, which runs once whether it lands or is taken over); a close ends
    /// them all. Chromium's maximize and restore likewise give the content its final bounds once
    /// and animate only a layer (ash/wm/window_animations.cc `CrossFadeAnimation`).
    public static func beginFrameAnimation(_ window: NSWindow) { LiveResizeWindows.shared.beginFrameAnimation(of: window) }

    /// Ends one ``beginFrameAnimation(_:)`` of `window`.
    public static func endFrameAnimation(_ window: NSWindow) { LiveResizeWindows.shared.endFrameAnimation(of: window) }

    /// Whether content sized by `window` holds its resize until the window lands at its size: a full
    /// screen transition or a frame animation cmux started (``beginFrameAnimation(_:)``).
    /// `ResizeCoordinator` holds terminal grids while it is true.
    public static func holdsContentResize(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return LiveResizeWindows.shared.isTransitioning(window) || LiveResizeWindows.shared.isFrameAnimating(window)
    }

    /// Some window is between `willEnterFullScreen` and `didEnterFullScreen`
    /// (or the exit pair): terminals hold their grid for the daemon until it
    /// ends (`ResizeCoordinator`), so the PTY reflows once, at the final size.
    public static var isFullScreenTransitioning: Bool { LiveResizeWindows.shared.isFullScreenTransitionActive }

    /// Whether `window` is between `willEnterFullScreen` and `didEnterFullScreen` (or the exit pair):
    /// its terminals hold their grid until it ends (`ResizeCoordinator`); other windows' do not.
    public static func isFullScreenTransitioning(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return LiveResizeWindows.shared.isTransitioning(window)
    }

    /// Ends `window`'s full screen transition that AppKit gave up on: its
    /// delegate's `windowDidFailToEnterFullScreen` or
    /// `windowDidFailToExitFullScreen` (no notification is posted for them).
    public static func fullScreenTransitionFailed(_ window: NSWindow) { LiveResizeWindows.shared.endTransition(of: window) }

    /// Returns true once no window is entering or leaving full screen (at once when none is), or false when the
    /// task was cancelled. The oracle's settle awaits it after the motion clocks (`debug.oracle.settle`): AppKit's
    /// full screen animation runs on no `MotionClock`, and `styleMask` has `.fullScreen` from its start.
    public static func fullScreenTransitionsEnded() async -> Bool { await LiveResizeWindows.shared.transitionsEnded() }

    /// True once no motion clock steps an animator (the windows' and the app clock window-less views share) and
    /// no window is in a full screen transition, false when cancelled: the motion half of the oracle's settle.
    /// Each wait is the clock's or the transitions' own; one that starts again while another is awaited is found
    /// on the next pass. Chromium's mac widget reports a full screen change when its transition completes, not
    /// when it starts (ui/views/cocoa/native_widget_mac_ns_window_host.cc OnWindowFullscreenTransitionComplete).
    public static func waitAtRest(_ windows: @MainActor @Sendable () -> [NSWindow]) async -> Bool {
        while let wait = nextRestWait(windows()) {
            guard await wait() else { return false }
        }
        return true
    }

    /// The traces of the animators running now, on every clock that can step one (no clock is created), and
    /// `window.fullScreenTransition` for each window AppKit moves into or out of full screen.
    public static func running(in windows: [NSWindow]) -> [String] {
        MotionClock.existing(in: windows).filter { !$0.isIdle }.flatMap(\.running)
            + windows.filter { isFullScreenTransitioning($0) }.map { _ in "window.fullScreenTransition" }
    }

    /// The wait for what still moves now: a clock that steps an animator, else a full screen transition; nil
    /// when nothing does.
    private static func nextRestWait(_ windows: [NSWindow]) -> (() async -> Bool)? {
        if let busy = MotionClock.existing(in: windows).first(where: { !$0.isIdle }) { return { await busy.waitIdle() } }
        if isFullScreenTransitioning { return { await fullScreenTransitionsEnded() } }
        return nil
    }

    /// Tests set a live resize here instead of posting AppKit's notifications
    /// to the process-wide center (check-test-notification-centers.sh).
    static var liveResizeOverride: Bool?
}

/// The windows between `willStartLiveResize` and `didEndLiveResize`, and the
/// windows in a full screen transition (`willEnterFullScreen` to
/// `didEnterFullScreen`, and the exit pair; a failed one ends through
/// ``Motion/fullScreenTransitionFailed(_:)``, AppKit posts nothing for it).
/// Observes every window from the first read of `Motion.basePolicy`, long before
/// a person can drag an edge.
final class LiveResizeWindows {
    static let shared = LiveResizeWindows()
    private var resizing: Set<ObjectIdentifier> = []
    private var transitioning: Set<ObjectIdentifier> = [] {
        didSet { resumeTransitionWaiters() }
    }
    private var transitionWaiters: [UInt64: AsyncStream<Void>.Continuation] = [:]
    private var lastTransitionWaiterID: UInt64 = 0
    /// The windows whose frame AppKit animates for cmux, with how many of those animations are open.
    private var frameAnimations: [ObjectIdentifier: Int] = [:]

    /// A frame animation does not count: it holds only its own window's content (``isFrameAnimating(_:)``).
    var isActive: Bool { !resizing.isEmpty || !transitioning.isEmpty }
    func isFrameAnimating(_ window: NSWindow) -> Bool { frameAnimations[ObjectIdentifier(window)] != nil }

    /// One more frame animation of `window` is open (``Motion/beginFrameAnimation(_:)``).
    func beginFrameAnimation(of window: NSWindow) { frameAnimations[ObjectIdentifier(window), default: 0] += 1 }

    /// One frame animation of `window` ended; the window holds nothing once its last one has.
    func endFrameAnimation(of window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard let open = frameAnimations[id] else { return }
        frameAnimations[id] = open > 1 ? open - 1 : nil
    }

    /// Some window is entering or leaving full screen.
    var isFullScreenTransitionActive: Bool { !transitioning.isEmpty }
    func isTransitioning(_ window: NSWindow) -> Bool { transitioning.contains(ObjectIdentifier(window)) }
    /// A transition AppKit gave up on (`windowDidFailToEnterFullScreen`, `windowDidFailToExitFullScreen`).
    func endTransition(of window: NSWindow) { transitioning.remove(ObjectIdentifier(window)) }

    /// True once no window is in a full screen transition, false when the task was cancelled: one signal sent
    /// where the last transition ends (its did-enter or did-exit notification, a failure, a close), as
    /// `MotionClock.waitIdle()` resumes where its last animator stops. The stream's iteration ends on cancel.
    func transitionsEnded() async -> Bool {
        if transitioning.isEmpty { return true }
        lastTransitionWaiterID &+= 1
        let id = lastTransitionWaiterID
        let (ended, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        transitionWaiters[id] = signal
        for await _ in ended { break }
        transitionWaiters.removeValue(forKey: id)?.finish()
        return !Task.isCancelled
    }

    /// ``transitionsEnded()`` callers parked now (tests).
    var transitionWaiterCount: Int { transitionWaiters.count }

    private func resumeTransitionWaiters() {
        guard transitioning.isEmpty, !transitionWaiters.isEmpty else { return }
        let waiters = transitionWaiters
        transitionWaiters.removeAll()
        for signal in waiters.values {
            signal.yield()
            signal.finish()
        }
    }

    init(center: NotificationCenter = .default) {
        // (name, starts a resize, closes the window).
        // raw-observer-allow: the sets need each notice's sender window; an AppEvents call carries none
        let changes: [(Notification.Name, Bool, Bool)] = [(NSWindow.willStartLiveResizeNotification, true, false), (NSWindow.didEndLiveResizeNotification, false, false), (NSWindow.willCloseNotification, false, true)]
        for (name, resizing, closes) in changes {
            // The token lives as long as the process: this object never goes away.
            // raw-observer-allow: the app's one observer per name; the sets need each notice's sender window
            _ = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                let id = ObjectIdentifier(window)
                MainActor.assumeIsolated { // main-proof: AppKit posts window notifications on the main thread
                    if resizing { self?.resizing.insert(id) } else { self?.resizing.remove(id) }
                    if closes {
                        self?.transitioning.remove(id)
                        self?.frameAnimations[id] = nil
                    }
                }
            }
        }
        // raw-observer-allow: the transition set needs each notice's sender window; an AppEvents call carries none
        let transitions: [(Notification.Name, Bool)] = [(NSWindow.willEnterFullScreenNotification, true), (NSWindow.didEnterFullScreenNotification, false), (NSWindow.willExitFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)]
        for (name, starts) in transitions {
            // The token lives as long as the process: this object never goes away.
            // raw-observer-allow: the app's one observer per name; the set needs each notice's sender window
            _ = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                let id = ObjectIdentifier(window)
                MainActor.assumeIsolated { // main-proof: AppKit posts window notifications on the main thread
                    if starts { self?.transitioning.insert(id) } else { self?.transitioning.remove(id) }
                }
            }
        }
    }
}
