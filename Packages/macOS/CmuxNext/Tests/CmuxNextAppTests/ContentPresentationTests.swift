import CmuxNextControl
import Synchronization
import Testing
@testable import CmuxNextApp

/// A pane that comes on screen (a split's new pane) shows its content in the
/// same frame, within the one-new-surface-per-frame budget.
@MainActor
struct ContentPresentationTests {
    @Test func aPaneComingOnScreenShowsInTheSameFrame() {
        let frames = HandFrames()
        let scheduler = ContentPresentationScheduler(frames: frames)
        let pane = FakePane()
        #expect(scheduler.showNow(pane))
        #expect(pane.shown == 1)
        #expect(pane.selectedContentIsAlive)
    }

    @Test func aSecondNewSurfaceInOneFrameWaitsForTheNextFrame() {
        let frames = HandFrames()
        let scheduler = ContentPresentationScheduler(frames: frames)
        let first = FakePane(), second = FakePane()
        #expect(scheduler.showNow(first))
        #expect(!scheduler.showNow(second))
        #expect(second.shown == 0)
        frames.fire()
        #expect(second.shown == 1)
        // The budget refills once a frame passes with no creation.
        frames.fire()
        let third = FakePane()
        #expect(scheduler.showNow(third))
    }

    @Test func liveContentIgnoresTheBudget() {
        let frames = HandFrames()
        let scheduler = ContentPresentationScheduler(frames: frames)
        #expect(scheduler.showNow(FakePane()))
        let alive = FakePane()
        alive.selectedContentIsAlive = true
        #expect(scheduler.showNow(alive))
        #expect(alive.shown == 1)
    }

    @Test func showingNowDropsAQueuedShow() {
        let frames = HandFrames()
        let scheduler = ContentPresentationScheduler(frames: frames)
        let pane = FakePane()
        scheduler.setNeedsShowSelected(pane)
        #expect(scheduler.showNow(pane))
        frames.fire()
        #expect(pane.shown == 1)
    }
}

@MainActor
private final class FakePane: PresentablePane {
    var selectedContentIsAlive = false
    var shown = 0
    func showSelected() {
        shown += 1
        selectedContentIsAlive = true
    }
}

private final class HandFrames: ControlFrameSource {
    private let pending = Mutex<[@MainActor @Sendable () -> Void]>([])

    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
        pending.withLock { $0.append(work) }
    }

    @MainActor
    func fire() {
        let works = pending.withLock { works in
            defer { works.removeAll() }
            return works
        }
        for work in works { work() }
    }
}
