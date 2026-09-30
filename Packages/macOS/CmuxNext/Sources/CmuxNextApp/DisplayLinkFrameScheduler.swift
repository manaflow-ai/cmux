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
///
/// A display link stops firing while the displays sleep and when its screen
/// goes away, yet the daemon mirror and the CLI work queue must keep moving.
/// So while work is pending a stall deadline runs on the injected clock:
/// when no frame came in time the work runs anyway, and after repeated
/// stalls the link is rebuilt on the current main screen.
@MainActor
final class DisplayLinkFrameScheduler: NSObject, FrameScheduler {
    typealias LinkFactory = @MainActor (DisplayLinkFrameScheduler) -> (any FrameLink)?

    /// Longest wait for a frame before pending work runs without one.
    static let stallTimeout: Duration = .milliseconds(100)
    /// Consecutive stalls after which the link is replaced.
    static let stallsBeforeRebuild = 3

    private var pending: [@MainActor @Sendable () -> Void] = []
    private var link: (any FrameLink)?
    private let makeLinkOverride: LinkFactory?
    private let clock: any Clock<Duration>
    private var stallDeadline: Task<Void, Never>?
    private var stalls = 0

    /// `makeLink` replaces the screen's display link (tests).
    init(clock: any Clock<Duration> = ContinuousClock(), makeLink: LinkFactory? = nil) {
        self.clock = clock
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
        armStallDeadline()
    }

    private func armStallDeadline() {
        guard stallDeadline == nil else { return }
        let clock = clock
        stallDeadline = Task { [weak self] in
            do { try await clock.sleep(for: Self.stallTimeout) } catch { return }
            self?.frameStalled()
        }
    }

    /// No frame within `stallTimeout` while work was pending.
    private func frameStalled() {
        stallDeadline = nil
        guard !pending.isEmpty else { return }
        stalls += 1
        if stalls >= Self.stallsBeforeRebuild {
            stalls = 0
            link?.invalidate()
            link = nil
        }
        drain()
        guard !pending.isEmpty else { return }
        (link ?? makeLink())?.isPaused = false
        armStallDeadline()
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
        stallDeadline?.cancel()
        stallDeadline = nil
        stalls = 0
        drain()
        if pending.isEmpty { link?.isPaused = true } else { armStallDeadline() }
    }

    private func drain() {
        let works = pending
        pending.removeAll(keepingCapacity: true)
        for work in works { work() }
    }
}
