public import AppKit
import CmuxNextWakeups

/// The window's display frames (``FrameClient`` on its ``FrameScheduler``).
@MainActor final class AgentPaneWindowFrames: AgentPaneFrameTicks {
    var onTick: (@MainActor () -> Void)?
    private var client: FrameClient?

    init(view: NSView) {
        client = FrameClient(owner: "agent-pane.transport", isAnimation: false,
                             scheduler: { [weak view] in view.map(FrameScheduler.forView) ?? .app }) { [weak self] tick in
            // A synthesized tick (the scheduler's stall deadline) is not a live display link.
            if tick.refreshInterval != nil { self?.onTick?() }
            return false
        }
    }

    func activate() { client?.activate() }
    func deactivate() { client?.deactivate() }
}

/// The pacer's fallback on a ``MainDeadline`` of the app's deadline scheduler: `visible`, as the frames it
/// delivers are what a shown chat draws, and precise, as its waits are a frame's (20 ms, a frame interval).
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
