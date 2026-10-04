public import AppKit
import CmuxNextWakeups

/// Paces the transport's pushes to the page by display frames: the first frame after a quiet
/// moment goes on the next main-loop turn (no added latency when idle), and while a burst lasts
/// the rest go in one bridge call per display frame (a 2,000-frame burst is a few dozen calls, not
/// 2,000), on the window's ``FrameScheduler``, which stops when the queue is empty.
@MainActor public final class AgentPaneFramePacer: AgentPaneTransportPacer {
    /// A flush closer than this to the previous one waits for the next display frame.
    public static let quietInterval: TimeInterval = 1.0 / 120
    private var client: FrameClient?
    private var pending: (@MainActor @Sendable () -> Bool)?
    private var leadingScheduled = false
    private var lastFlush: TimeInterval = 0
    private let now: @MainActor () -> TimeInterval

    public init(view: NSView, now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        client = FrameClient(owner: "agent-pane.transport", isAnimation: false,
                             scheduler: { [weak view] in view.map(FrameScheduler.forView) ?? .app }) { [weak self] _ in
            self?.tick() ?? false
        }
    }

    public func schedule(_ flush: @escaping @MainActor @Sendable () -> Bool) {
        pending = flush
        guard client?.isActive != true, !leadingScheduled else { return }
        if now() - lastFlush >= Self.quietInterval {
            leadingScheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.leadingScheduled = false
                    if self.run() { self.client?.activate() }
                }
            }
        } else {
            client?.activate()
        }
    }

    private func tick() -> Bool { run() }

    private func run() -> Bool {
        lastFlush = now()
        guard let pending else { return false }
        let more = pending()
        if !more { self.pending = nil }
        return more
    }

    /// Stops pacing (the pane closed).
    public func stop() {
        pending = nil
        client?.deactivate()
        client = nil
    }
}
