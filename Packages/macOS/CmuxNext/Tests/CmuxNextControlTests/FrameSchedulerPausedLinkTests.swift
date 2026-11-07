import CmuxNextWakeups
import Foundation
import QuartzCore
import Testing

/// An idle frame scheduler pauses its display link and keeps it; the next motion resumes that link
/// (RESIZE P0 3, m50 item 2). Chrome's model: the begin-frame source stays, it is paused while
/// nothing needs frames and resumed on demand; it is not torn down and rebuilt per burst.
///
/// The scheduler dropped its link on every idle, so each key press that started a motion made a new
/// display link inside its own input turn (`window.displayLink`, then `add(to:forMode:)`), and that
/// new link's first frame came off the vsync grid. A paused link delivers no callbacks, so keeping
/// it costs no idle wakeups.
@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameSchedulerPausedLinkTests {
    @MainActor
    private final class Link: FrameLink {
        var isPaused = false
        private(set) var invalidated = false
        func invalidate() { invalidated = true }
    }

    @MainActor
    private final class Links {
        private(set) var made: [Link] = []
        func make() -> Link {
            let link = Link()
            made.append(link)
            return link
        }
    }

    @MainActor
    private final class Media {
        var now: CFTimeInterval = 500
        var read: @MainActor () -> CFTimeInterval { { [self] in self.now } }
    }

    private static let refresh = 1.0 / 120

    /// Fires `count` display frames of the 120 Hz refresh.
    private static func frames(_ count: Int, on scheduler: FrameScheduler, media: Media) {
        for _ in 0..<count {
            media.now += refresh
            scheduler.frameDidFire(timestamp: media.now, refreshInterval: refresh)
        }
    }

    @Test func aMotionAfterIdleTicksOnTheKeptLink() throws {
        let links = Links()
        let media = Media()
        let scheduler = FrameScheduler.testing(mediaTime: media.read) { _ in links.make() }
        var ticks = 0
        let spring = FrameClient(owner: "spring", on: scheduler) { _ in
            ticks += 1
            return true
        }
        spring.activate()
        Self.frames(3, on: scheduler, media: media)
        spring.deactivate()

        // Idle: the link stays, paused (no frame callbacks), and the scheduler does not run.
        let link = try #require(links.made.first)
        #expect(links.made.count == 1)
        #expect(!link.invalidated, "the idle scheduler tore down its display link: the next motion makes a new one in its input turn")
        #expect(link.isPaused, "the idle scheduler's link still runs: frame wakeups while idle")
        #expect(!scheduler.isRunning)
        #expect(scheduler.hasLink, "the idle scheduler dropped its paused link")

        // The next motion (a key press after the spring rested) resumes the same link in its turn.
        media.now += 2
        spring.activate()
        #expect(links.made.count == 1, "a motion after idle made a new display link (\(links.made.count) made)")
        #expect(scheduler.linksMade == 1)
        #expect(!link.isPaused, "the kept link did not resume")
        #expect(scheduler.isRunning)

        // Its first frame is the kept link's next tick, one refresh of motion.
        var first: Double?
        let next = FrameClient(owner: "next spring", on: scheduler) { tick in
            if first == nil { first = tick.elapsed }
            return true
        }
        next.activate()
        Self.frames(1, on: scheduler, media: media)
        #expect(ticks == 4, "the first frame after idle did not tick the motion")
        #expect(abs((first ?? 0) - Self.refresh) < 1e-9, "the first frame after idle stepped \(first ?? -1) s, not one refresh")
        spring.deactivate()
        next.deactivate()
    }

    /// Bursts of motion with idle between them (the four key presses of a resize film) all run on one link.
    @Test func burstsWithIdleBetweenThemShareOneLink() {
        let links = Links()
        let media = Media()
        let scheduler = FrameScheduler.testing(mediaTime: media.read) { _ in links.make() }
        let spring = FrameClient(owner: "spring", on: scheduler) { _ in true }
        for _ in 0..<4 {
            spring.activate()
            Self.frames(40, on: scheduler, media: media)
            spring.deactivate()
            media.now += 0.6
        }
        #expect(links.made.count == 1, "\(links.made.count) display links for 4 bursts")
        #expect(links.made.allSatisfy { !$0.invalidated })
        #expect(!scheduler.isRunning)
    }

    /// A scheduler freed without ``FrameScheduler/invalidate()`` (its window freed without a close) invalidates its
    /// kept link: the run loop retains a link until it is invalidated, and a paused link never ticks to find out.
    @Test func aFreedSchedulerInvalidatesItsPausedLink() throws {
        let links = Links()
        let media = Media()
        weak var freed: FrameScheduler?
        do {
            let scheduler = FrameScheduler.testing(mediaTime: media.read) { _ in links.make() }
            freed = scheduler
            let spring = FrameClient(owner: "spring", on: scheduler) { _ in true }
            spring.activate()
            Self.frames(2, on: scheduler, media: media)
            spring.deactivate()
        }
        #expect(freed == nil, "the idle scheduler was kept alive")
        // The next scheduler to go idle sweeps the links of freed ones.
        let other = FrameScheduler.testing(mediaTime: media.read) { _ in links.make() }
        let next = FrameClient(owner: "next", on: other) { _ in true }
        next.activate()
        Self.frames(1, on: other, media: media)
        next.deactivate()
        let link = try #require(links.made.first)
        #expect(link.invalidated, "a freed scheduler left its paused display link in the run loop")
        #expect(links.made.count == 2 && !links.made[1].invalidated, "the live scheduler's kept link was invalidated")
    }

    /// The window closing still ends the link (a link retains its target until it is invalidated).
    @Test func closingTheWindowInvalidatesThePausedLink() throws {
        let links = Links()
        let media = Media()
        let scheduler = FrameScheduler.testing(mediaTime: media.read) { _ in links.make() }
        let spring = FrameClient(owner: "spring", on: scheduler) { _ in true }
        spring.activate()
        Self.frames(2, on: scheduler, media: media)
        spring.deactivate()
        scheduler.invalidate()
        let link = try #require(links.made.first)
        #expect(link.invalidated, "the closed window's paused link was not invalidated")
        #expect(!scheduler.hasLink)
        #expect(!scheduler.isRunning)
    }
}
