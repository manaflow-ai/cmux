import CmuxNextWakeups
import Foundation
import QuartzCore
import Testing
@testable import CmuxNextBrowser

/// The CEF pump under a late frame (plans/cmux-next/chrome-parity/p06-scheduler.md, "Rendering
/// starvation guard": CEF pump slices beyond one per frame wait): while a shown window's link is
/// late, the pump runs one pass for that late frame; the next waits for the link's tick and then
/// runs on the next run loop pass.
@MainActor
@Suite struct CEFMessagePumpStarvationTests {
    @Test func aLateFrameLetsOnePassRunAndHoldsTheNextUntilItsTick() {
        let media = Media()
        let window = FrameScheduler.testing(mediaTime: media.read) { _ in Link() }
        let starvation = RenderStarvationGuard(holdsWork: true, visibility: Shown(), mediaTime: media.read)
        starvation.watch(window)
        let spring = FrameClient(owner: "spring", on: window) { _ in true }
        let timer = Timer()
        var passes = 0
        let pump = CEFMessagePump(work: { passes += 1 }, timer: timer, clock: { media.now },
                                  ledger: WakeupLedger(), starvation: starvation)
        pump.start()
        timer.fire()
        #expect(passes == 1, "nothing is late: the start's pass runs")
        spring.activate()
        window.frameDidFire(timestamp: media.now, refreshInterval: 1.0 / 60)
        media.now += 0.2
        pump.scheduleNow()
        timer.fire()
        #expect(passes == 2, "the late frame's one pass")
        pump.scheduleNow()
        timer.fire()
        #expect(passes == 2, "the next pass waits for the late link")
        #expect(timer.armed == nil, "a held pump does not spin on its timer")
        #expect(pump.stats.lateFrameHolds == 1)
        #expect(starvation.stats.heldSlices == 1)
        // A request while held keeps waiting, without a second wait.
        pump.scheduleNow()
        timer.fire()
        #expect(passes == 2)
        window.frameDidFire(timestamp: media.now, refreshInterval: 1.0 / 60)
        #expect(timer.armed == 0, "the late link's tick re-arms the pump for the next run loop pass")
        #expect(passes == 2, "never inside the frame tick")
        timer.fire()
        #expect(passes == 3)
        spring.deactivate()
        pump.stop()
    }

    @Test func aReportOnlyGuardNeverHoldsThePump() {
        let media = Media()
        let window = FrameScheduler.testing(mediaTime: media.read) { _ in Link() }
        let starvation = RenderStarvationGuard(holdsWork: false, visibility: Shown(), mediaTime: media.read)
        starvation.watch(window)
        let spring = FrameClient(owner: "spring", on: window) { _ in true }
        let timer = Timer()
        var passes = 0
        let pump = CEFMessagePump(work: { passes += 1 }, timer: timer, clock: { media.now },
                                  ledger: WakeupLedger(), starvation: starvation)
        pump.start()
        spring.activate()
        window.frameDidFire(timestamp: media.now, refreshInterval: 1.0 / 60)
        media.now += 0.2
        for _ in 0..<3 {
            pump.scheduleNow()
            timer.fire()
        }
        #expect(passes == 3)
        #expect(pump.stats.lateFrameHolds == 0)
        #expect(starvation.stats.events == 1, "it still reports the late period")
        spring.deactivate()
        pump.stop()
    }

    /// The pump's timer, fired by hand.
    final class Timer: CEFPumpTimer {
        var onFire: (() -> Void)?
        var armed: TimeInterval?
        func arm(after delay: TimeInterval, tolerance: TimeInterval) { armed = delay }
        func disarm() { armed = nil }
        func invalidate() { armed = nil }
        func fire() {
            armed = nil
            onFire?()
        }
    }

    /// The media clock of the window link, the guard and the pump, moved by hand.
    final class Media {
        var now: CFTimeInterval = 100
        var read: @MainActor () -> CFTimeInterval { { [self] in self.now } }
    }

    final class Link: FrameLink {
        var isPaused = false
        func invalidate() {}
    }

    /// Every scheduler's frames show.
    struct Shown: RenderVisibility {
        func showsFrames(of scheduler: FrameScheduler) -> Bool { true }
    }
}
