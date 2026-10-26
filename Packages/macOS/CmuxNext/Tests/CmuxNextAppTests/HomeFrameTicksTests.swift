import AppKit
@testable import CmuxNextHome
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import MessagesLabHome
import Testing

/// Home's FrameTick runs on the pane window's FrameScheduler (p14-energy-050): one `.motion` batch
/// client per transcript that ticks while work waits and leaves the scheduler on the frame with none,
/// so Home makes no display link of its own.
@MainActor @Suite struct HomeFrameTicksTests {
    @MainActor private final class Frames {
        var count = 0
        var more = true
        weak var resolvedFor: NSView?
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
}

@MainActor
private final class HomeFrameTicksTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
