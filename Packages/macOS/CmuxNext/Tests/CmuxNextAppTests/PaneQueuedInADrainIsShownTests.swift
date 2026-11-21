import AppKit
@testable import CmuxNextApp
import CmuxNextControl
import Testing

/// SPLIT OPEN CHAT (review of #40670): a pane's show can queue ANOTHER pane while the scheduler drains its queue
/// (`PaneController.showSelected` syncs a stale strip from the store; that sync can apply the layout, and the apply
/// queues a second stale pane or a pane it mounts). The drain then replaced its queue with the panes it kept for a
/// later frame, so the pane queued in the drain stayed in `pending` with no place in the queue: it was never shown
/// from the queue, and the scheduler asked for a frame at every refresh for nothing.
@MainActor @Suite(.serialized)
struct PaneQueuedInADrainIsShownTests {
    /// A pane whose selected content needs a new surface; its show can do more work (`onShow`).
    @MainActor final class Pane: PresentablePane {
        let name: String
        let isFocusedInWorkspace: Bool
        var onShow: () -> Void = {}
        private let record: (String) -> Void
        private(set) var selectedContentIsAlive = false
        init(_ name: String, focused: Bool = false, record: @escaping (String) -> Void) {
            (self.name, isFocusedInWorkspace, self.record) = (name, focused, record)
        }
        func showSelected() {
            selectedContentIsAlive = true
            record(name)
            onShow()
        }
        func showWhileWaiting() {}
    }

    /// Display frames the test runs, counted: `fire()` runs the frames asked for so far and says how many there were.
    final class CountedFrames: ControlFrameSource, @unchecked Sendable { // touched on the main actor only
        nonisolated(unsafe) private var pending: [@MainActor @Sendable () -> Void] = [] // main actor only
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { pending.append(work) }
        @MainActor @discardableResult func fire() -> Int {
            let due = pending
            pending = []
            due.forEach { $0() }
            return due.count
        }
    }

    /// A pane that a show queues inside the drain is shown on a later frame, after the panes that waited before it,
    /// and the scheduler asks for no frame when all are shown.
    @Test func aPaneQueuedWhileTheQueueDrainsIsShownOnALaterFrame() {
        var shown: [String] = []
        let frames = CountedFrames()
        let scheduler = ContentPresentationScheduler(frames: frames)
        let waiting = Pane("waiting") { shown.append($0) }, late = Pane("late") { shown.append($0) }
        let first = Pane("first", focused: true) { shown.append($0) }
        // The focused pane's show queues another pane, as a stale strip's sync does through a layout apply.
        first.onShow = { scheduler.setNeedsShowSelected(late) }
        scheduler.setNeedsShowSelected(waiting)
        scheduler.setNeedsShowSelected(first)
        frames.fire()
        #expect(shown == ["first"], "the focused pane's surface is this frame's one surface: \(shown)")
        frames.fire()
        frames.fire()
        #expect(shown == ["first", "waiting", "late"],
                "the pane queued while the queue drained is not shown after the pane that waited before it: \(shown)")
        // All are shown: the frame that follows the last surface clears the budget, and then no frame is asked.
        frames.fire()
        let idle = (0..<3).map { _ in frames.fire() }
        #expect(idle == [0, 0, 0], "the scheduler still asks for frames with nothing to show: \(idle) per refresh")
    }

    /// The same for a pane whose content is alive (it needs no surface): it shows on the next frame.
    @Test func anAlivePaneQueuedWhileTheQueueDrainsIsShownOnTheNextFrame() {
        var shown: [String] = []
        let frames = CountedFrames()
        let scheduler = ContentPresentationScheduler(frames: frames)
        let late = Pane("late") { shown.append($0) }
        late.showSelected() // its content is alive from here
        shown = []
        let first = Pane("first") { shown.append($0) }
        first.onShow = { scheduler.setNeedsShowSelected(late) }
        scheduler.setNeedsShowSelected(first)
        frames.fire()
        #expect(shown == ["first"])
        frames.fire()
        #expect(shown == ["first", "late"], "the pane queued while the queue drained is not shown on the next frame: \(shown)")
    }
}
