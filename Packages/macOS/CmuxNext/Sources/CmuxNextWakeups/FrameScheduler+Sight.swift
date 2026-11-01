public import AppKit
import CmuxNextCompat

/// Frames only for what the person can see (Chrome's rule for a hidden tab: no animation frames, and
/// the page shows its final state when it is shown again). A window out of sight gets no animation
/// frames: an animation client that starts in it, or is running when it goes out of sight, ends at
/// once at its final state (its completions run), and the window's display link goes with the last
/// client. Clients that are not animations (the daemon mirror, batch drains) keep ticking, on the
/// link or on the stall deadline, as before.
///
/// Out of sight: the window was on screen once and now is ordered out, minimized, or fully covered
/// (on another Space, under other windows, its app hidden), as WindowServer last reported its
/// occlusion. A window never on screen is not judged: windows are built before they show (instant
/// create), and tests drive frames into windows they never show.
extension FrameScheduler {
    /// Whether `window` is out of the person's sight now (see the extension's comment).
    public static func windowIsOutOfSight(_ window: NSWindow) -> Bool { // perf-hot: 0.5ms frame-tick (every frame)
        watchSight()
        guard let note = objc_getAssociatedObject(window, &sightKey) as? SightNote else { return false }
        if window.isMiniaturized { return true }
        // The window the person works in is in sight, whatever WindowServer last said: after Cmd-Tab
        // or a Space switch back, its occlusion report comes a moment later.
        if NSApp.isActive, window.isKeyWindow || window.isMainWindow { return false }
        guard window.isVisible else {
            // Ordered out. Forget a cover seen while it was shown: when it is ordered back in, it is in
            // sight until WindowServer reports otherwise.
            note.coveredWhileShown = false
            return true
        }
        return note.coveredWhileShown && !window.occlusionState.contains(.visible)
    }

    /// Whether this scheduler's window is out of sight (never for the screen schedulers).
    var isOutOfSight: Bool {
        guard let window else { return false }
        return Self.windowIsOutOfSight(window)
    }

    /// Ends an animation client now: it stops, then its own settle puts its work at its final state
    /// in one go (the window's Motion clock snaps its springs, the layout lays out its final frames
    /// once; completions run). A client with no settle (an autoscroll, a probe, a drag ghost: work
    /// with no end of its own) just stops, and its owner starts it again when needed.
    func settle(_ client: FrameClient) {
        client.detach()
        client.settleNow?()
    }

    /// Starts the app's one occlusion observer (idempotent; held by ``app``). It records, per window,
    /// whether WindowServer reported it covered while it was ordered in, and ends the animations of
    /// a window that just went out of sight (only that window's scheduler is told).
    static func watchSight() {
        guard app.sightObserver == nil else { return }
        app.sightObserver = MainActorObservation(NSWindow.didChangeOcclusionStateNotification,
                                             read: { $0.object as? NSWindow }) { window in
            guard let window else { return }
            let note = (objc_getAssociatedObject(window, &sightKey) as? SightNote) ?? {
                let made = SightNote()
                objc_setAssociatedObject(window, &sightKey, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                return made
            }()
            note.coveredWhileShown = window.isVisible && !window.occlusionState.contains(.visible)
            if windowIsOutOfSight(window) { scheduler(of: window)?.endAnimations() }
        }
    }

    private static var sightKey: UInt8 = 0

    /// The scheduler `window` already has (none is made for it).
    static func scheduler(of window: NSWindow) -> FrameScheduler? {
        objc_getAssociatedObject(window, &associationKey) as? FrameScheduler
    }

    /// Ends every running animation client now (the window went out of sight), and drops the link
    /// when no client is left.
    func endAnimations() {
        for client in clients.values where client.isActive && client.isAnimation { end(client) }
        if clients.isEmpty { pause() }
    }

    /// Takes `client` off the frames and runs it to its end.
    func end(_ client: FrameClient) {
        drop(ObjectIdentifier(client))
        settle(client)
    }
}

/// What WindowServer last said about a window that has been on screen.
@MainActor
final class SightNote {
    var coveredWhileShown = false
}
