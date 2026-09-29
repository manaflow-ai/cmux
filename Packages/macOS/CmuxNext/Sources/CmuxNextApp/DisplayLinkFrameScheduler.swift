import AppKit
import CmuxNextDaemon
import QuartzCore

/// Runs daemon-store batches once per display frame (architecture.md 2).
/// The link is paused whenever nothing is pending, so an idle app has no
/// timer and no wakeups.
@MainActor
final class DisplayLinkFrameScheduler: NSObject, FrameScheduler {
    private var pending: [@MainActor @Sendable () -> Void] = []
    private var link: CADisplayLink?

    nonisolated func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in self.enqueue(work) }
    }

    private func enqueue(_ work: @escaping @MainActor @Sendable () -> Void) {
        pending.append(work)
        guard let link = link ?? makeLink() else {
            // No screen (headless launch): run on this turn.
            drain()
            return
        }
        link.isPaused = false
    }

    private func makeLink() -> CADisplayLink? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        return link
    }

    @objc private func tick(_ link: CADisplayLink) {
        drain()
        if pending.isEmpty { link.isPaused = true }
    }

    private func drain() {
        let works = pending
        pending.removeAll(keepingCapacity: true)
        for work in works { work() }
    }
}
