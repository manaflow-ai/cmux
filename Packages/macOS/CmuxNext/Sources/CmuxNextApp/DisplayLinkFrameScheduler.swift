import AppKit
import CmuxNextDaemon
import QuartzCore

/// What the scheduler needs from a display link (a fake in tests).
@MainActor
protocol FrameLink: AnyObject {
    var isPaused: Bool { get set }
    func invalidate()
}

extension CADisplayLink: FrameLink {}

/// Runs daemon-store batches once per display frame (architecture.md 2).
/// The link is paused whenever nothing is pending, so an idle app has no
/// timer and no wakeups.
@MainActor
final class DisplayLinkFrameScheduler: NSObject, FrameScheduler {
    typealias LinkFactory = @MainActor (DisplayLinkFrameScheduler) -> (any FrameLink)?

    private var pending: [@MainActor @Sendable () -> Void] = []
    private var link: (any FrameLink)?
    private let makeLinkOverride: LinkFactory?

    /// `makeLink` replaces the screen's display link (tests).
    init(makeLink: LinkFactory? = nil) {
        makeLinkOverride = makeLink
        super.init()
    }

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

    private func makeLink() -> (any FrameLink)? {
        let made: (any FrameLink)?
        if let makeLinkOverride {
            made = makeLinkOverride(self)
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            let display = screen.displayLink(target: self, selector: #selector(tick(_:)))
            display.add(to: .main, forMode: .common)
            made = display
        } else {
            made = nil
        }
        link = made
        return made
    }

    @objc private func tick(_ link: CADisplayLink) {
        frameDidFire()
    }

    /// One display frame (the link's tick; tests call it directly).
    func frameDidFire() {
        drain()
        if pending.isEmpty { link?.isPaused = true }
    }

    private func drain() {
        let works = pending
        pending.removeAll(keepingCapacity: true)
        for work in works { work() }
    }
}
