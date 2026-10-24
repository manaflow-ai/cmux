@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextControl
import Testing

/// #17587: the launch drops the panes' last frames no pane took only once every restored pane
/// presented its selection (`ContentPresentationScheduler.whenIdle`). The scheduler makes at most
/// one new surface per frame, so the 12 panes of STRESS present over about 12 frames: dropping the
/// frames at the launch settle (the first pane) left every later pane without its frame.
@MainActor @Suite struct ContentPresentationIdleTests {
    /// A frame source the test fires by hand.
    nonisolated final class Frames: ControlFrameSource {
        private let pending = Mutex<[@MainActor @Sendable () -> Void]>([])

        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
            pending.withLock { $0.append(work) }
        }

        @MainActor func fire() {
            let works = pending.withLock { works in
                defer { works.removeAll() }
                return works
            }
            for work in works { work() }
        }

        /// A display frame is booked and not fired yet.
        var isBooked: Bool { pending.withLock { !$0.isEmpty } }
    }

    /// A pane whose selection needs a new surface until it is shown; `onShow` runs inside its
    /// `showSelected()` (a shown page marking the launch's pane ready, whose waiters queue more).
    @MainActor final class Pane: PresentablePane {
        private(set) var shown = false
        var onShow: (@MainActor () -> Void)?
        var selectedContentIsAlive: Bool { shown }
        func showSelected() {
            shown = true
            onShow?()
        }
    }

    @Test func idleWorkWaitsUntilEveryQueuedPaneShowedItsSelection() {
        let frames = Frames()
        let scheduler = ContentPresentationScheduler(frames: frames)
        let panes = [Pane(), Pane(), Pane()]
        for pane in panes { scheduler.setNeedsShowSelected(pane) }
        var idle = false
        scheduler.whenIdle { idle = true }
        frames.fire()
        #expect(panes.map(\.shown) == [true, false, false], "one new surface per frame")
        #expect(!idle, "two panes still wait for their frame")
        frames.fire()
        #expect(!idle)
        frames.fire()
        #expect(panes.allSatisfy { $0.shown })
        #expect(idle, "the frame that showed the last pane ran the idle work")
    }

    @Test func idleWorkWithNothingQueuedRunsAtTheNextFrame() {
        let frames = Frames()
        let scheduler = ContentPresentationScheduler(frames: frames)
        var idle = false
        scheduler.whenIdle { idle = true }
        #expect(!idle, "not in the caller's turn: a pane the same turn queues still comes first")
        frames.fire()
        #expect(idle)
    }

    /// ec14f8345f5 review: a pane shown by the drain ran `LaunchReveal.markReady(.pane)`, whose
    /// waiter queued the deferred chat pane inside the drain; the drain then replaced the queue
    /// with the panes it had left and lost the chat. The chat stayed pending for good: it never
    /// showed, and every drain booked another display frame for the rest of the session.
    @Test func aPaneQueuedWhileTheDrainShowsAnotherShowsOnTheNextFrameAndTheFramesStop() {
        let frames = Frames()
        let scheduler = ContentPresentationScheduler(frames: frames)
        let page = Pane()
        let chat = Pane()
        page.onShow = { scheduler.setNeedsShowSelected(chat) }
        scheduler.setNeedsShowSelected(page)
        var idle = false
        scheduler.whenIdle { idle = true }
        frames.fire()
        #expect(page.shown)
        #expect(!chat.shown, "the page spent this frame's new surface")
        #expect(!idle, "the chat still waits for its frame")
        frames.fire()
        #expect(chat.shown, "the chat queued during the drain shows on the next frame")
        #expect(idle)
        frames.fire()
        #expect(!frames.isBooked, "an idle scheduler books no display frame")
    }
}
