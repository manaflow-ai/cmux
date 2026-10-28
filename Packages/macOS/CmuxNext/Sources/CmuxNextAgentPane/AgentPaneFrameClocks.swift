public import AppKit
import CmuxNextWakeups

/// The window's display frames (``FrameClient`` on its ``FrameScheduler``).
@MainActor final class AgentPaneWindowFrames: AgentPaneFrameTicks {
    var onTick: (@MainActor () -> Void)?
    private var client: FrameClient?
    private weak var view: NSView?

    init(view: NSView) {
        self.view = view
        // Motion rate: the link runs at the display's full rate up to 120 Hz (``frameInterval``).
        // frame-client: under load the next push to the page waits for a frame; it calls the web view, so on main
        client = FrameClient(owner: "agent-pane.transport", isAnimation: false, rate: .motion,
                             scheduler: { [weak view] in view.map(FrameScheduler.forView) ?? .app }) { [weak self] tick in
            // A synthesized tick (the scheduler's stall deadline) is not a live display link.
            if tick.refreshInterval != nil { self?.onTick?() }
            return false
        }
    }

    func activate() { client?.activate() }
    func deactivate() { client?.deactivate() }

    /// One frame of the screen the view's window is on now (so a window moved to another screen paces at that
    /// screen's rate from its next delivery): its shortest refresh interval (16.7 ms at 60 Hz, 8.3 ms on
    /// ProMotion), never shorter than a tick of the ``FrameRate/motion`` link it waits on (120 Hz at most).
    /// Nil with no window or screen.
    var frameInterval: TimeInterval? {
        guard let screen = view?.window?.screen else { return nil }
        return max(screen.minimumRefreshInterval, 1 / Double(FrameRate.motion.hertz))
    }
}

/// The pacer's fallback on a ``MainDeadline`` of the app's deadline scheduler: `visible`, as the frames it
/// delivers are what a shown chat draws, and precise, as its waits are a frame's (20 ms, a frame interval;
/// 40 ms for a 30 Hz display's missed frame, flexible as below).
/// A longer wait (a hidden pane's 250 ms) is flexible (``TimerAlignment/precise``: 36 ms and up), as
/// Chromium's `kPrecise` delayed tasks are (base/task/delay_policy.h).
@MainActor final class AgentPaneMainDeadline: AgentPaneFallbackDeadline {
    private let deadline: MainDeadline

    init(deadlines: MainDeadlineScheduler) {
        deadline = MainDeadline(owner: "agent-pane.transport.fallback", workClass: .visible, alignment: .precise, scheduler: deadlines)
    }

    func schedule(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) {
        deadline.schedule(after: delay, action)
    }

    func cancel() { deadline.cancel() }
}
