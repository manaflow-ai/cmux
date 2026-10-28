import AppKit
@testable import CmuxNextHome
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import MessagesLabHome
import Testing

/// Home's FrameTick runs on the pane window's FrameScheduler: one `.motion` batch
/// client per transcript that ticks while work waits and leaves the scheduler on the frame with none,
/// so Home makes no display link of its own.
@MainActor @Suite struct HomeFrameTicksTests {
    @MainActor private final class Frames {
        var count = 0
        var more = true
        weak var resolvedFor: NSView?
    }

    /// The window the pane is in: its scheduler is what the source resolves for the view.
    @MainActor private final class Window {
        var scheduler: FrameScheduler
        init(scheduler: FrameScheduler) { self.scheduler = scheduler }
    }

    @Test func aStartedStreamTicksOnTheWindowSchedulerUntilItsFrameFindsNoWork() throws {
        let scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in
            HomeFrameTicksTestLink()
        }
        let view = NSView()
        let frames = Frames()
        let source = HomeFrameTicks { asked in
            frames.resolvedFor = asked
            return scheduler
        }
        let stream = source.frames(for: view) {
            frames.count += 1
            return frames.more
        }
        let client = try #require((stream as? HomeFrameTickStream)?.client)
        #expect(client.rate == .motion, "Home typing is key to frame: never an ambient rate")
        #expect(!client.isAnimation, "batch work: an occluded window keeps ticking it")
        #expect(scheduler.activeClients.isEmpty, "no frames before the first request")

        stream.start()
        #expect(frames.resolvedFor === view)
        #expect(scheduler.activeClients == [HomeFrameTicks.owner])
        scheduler.frameDidFire(timestamp: 1000 + 1.0 / 120, refreshInterval: 1.0 / 120)
        #expect(frames.count == 1)
        #expect(scheduler.activeClients == [HomeFrameTicks.owner], "work posted in the frame keeps it ticking")

        frames.more = false
        scheduler.frameDidFire(timestamp: 1000 + 2.0 / 120, refreshInterval: 1.0 / 120)
        #expect(frames.count == 2)
        #expect(scheduler.activeClients.isEmpty, "the frame with no work left takes it off the scheduler")
        scheduler.frameDidFire(timestamp: 1000 + 3.0 / 120, refreshInterval: 1.0 / 120)
        #expect(frames.count == 2)

        stream.start()
        scheduler.frameDidFire(timestamp: 1000 + 4.0 / 120, refreshInterval: 1.0 / 120)
        #expect(frames.count == 3, "a later request starts the same client again")
        scheduler.invalidate()
    }

    @Test func aRestartedStreamLeavesTheOldWindowsSchedulerForTheNewOne() {
        let old = Self.scheduler()
        let new = Self.scheduler()
        let frames = Frames()
        let window = Window(scheduler: old)
        let view = NSView()  // held: the client resolves a weak view
        let stream = HomeFrameTicks { _ in window.scheduler }.frames(for: view) {
            frames.count += 1
            return true
        }

        stream.start()
        #expect(old.activeClients == [HomeFrameTicks.owner])
        window.scheduler = new  // the pane moved to another window while work still waits
        stream.restart()
        #expect(old.activeClients.isEmpty, "the old window's scheduler no longer ticks the pane")
        #expect(new.activeClients == [HomeFrameTicks.owner])
        old.frameDidFire(timestamp: 1000 + 1.0 / 120, refreshInterval: 1.0 / 120)
        #expect(frames.count == 0)
        new.frameDidFire(timestamp: 1000 + 1.0 / 120, refreshInterval: 1.0 / 120)
        #expect(frames.count == 1, "the waiting work runs on the new window's next frame")
        withExtendedLifetime(view) {}
        old.invalidate()
        new.invalidate()
    }

    @Test func aStreamItsClosedWindowDroppedRestartsOnTheNewWindow() {
        let old = Self.scheduler()
        let new = Self.scheduler()
        let frames = Frames()
        let window = Window(scheduler: old)
        let view = NSView()  // held: the client resolves a weak view
        let stream = HomeFrameTicks { _ in window.scheduler }.frames(for: view) {
            frames.count += 1
            return true
        }

        stream.start()
        old.invalidate()  // the window closed (its willClose observer): the client is dropped with no call back
        #expect(old.activeClients.isEmpty)
        window.scheduler = new
        stream.restart()
        #expect(new.activeClients == [HomeFrameTicks.owner])
        new.frameDidFire(timestamp: 1000 + 1.0 / 120, refreshInterval: 1.0 / 120)
        #expect(frames.count == 1, "the work that waited when the window closed runs on the new window's next frame")
        withExtendedLifetime(view) {}
        new.invalidate()
    }

    private static func scheduler() -> FrameScheduler {
        FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in
            HomeFrameTicksTestLink()
        }
    }
}

@MainActor
private final class HomeFrameTicksTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
