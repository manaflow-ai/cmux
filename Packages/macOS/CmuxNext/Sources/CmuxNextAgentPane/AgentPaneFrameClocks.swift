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

/// The pacer's fallback on a ``DemandTimer``.
@MainActor final class AgentPaneDemandDeadline: AgentPaneFallbackDeadline {
    private let timer = DemandTimer(owner: "agent-pane.transport.fallback")

    func schedule(after delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) {
        timer.schedule(after: delay) { @MainActor in action() }
    }

    func cancel() { timer.cancel() }
}
