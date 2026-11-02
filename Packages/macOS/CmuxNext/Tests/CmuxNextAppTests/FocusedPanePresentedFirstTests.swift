import AppKit
@testable import CmuxNextApp
import CmuxNextControl
import Testing

/// REOPEN-F4 (STATUS 4618): panes waiting for their first surface get one per frame
/// (`ContentPresentationScheduler`), and the focused pane waited behind the others in their queue
/// order, so the first key typed into a reopened window's focused terminal came before its surface.
@MainActor @Suite(.serialized)
struct FocusedPanePresentedFirstTests {
    /// A pane whose selected content needs a new surface.
    @MainActor final class Cold: PresentablePane {
        let name: String
        let isFocusedInWorkspace: Bool
        private let record: (String) -> Void
        var selectedContentIsAlive: Bool { false }
        init(_ name: String, focused: Bool = false, record: @escaping (String) -> Void) {
            (self.name, isFocusedInWorkspace, self.record) = (name, focused, record)
        }
        func showSelected() { record(name) }
    }

    /// Display frames the test runs: `fire()` runs the frame asked for so far.
    final class ManualFrames: ControlFrameSource, @unchecked Sendable { // touched on the main actor only
        nonisolated(unsafe) private var pending: [@MainActor @Sendable () -> Void] = [] // main actor only
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { pending.append(work) }
        @MainActor func fire() {
            let due = pending
            pending = []
            due.forEach { $0() }
        }
    }

    /// Panes waiting for their surfaces (one per frame): the focused one is shown on the next frame,
    /// whatever its place in the queue; the others follow one per frame, as before.
    @Test func theQueuedFocusedPaneGetsTheNextFramesSurface() {
        var shown: [String] = []
        let frames = ManualFrames()
        let scheduler = ContentPresentationScheduler(frames: frames)
        let a = Cold("a") { shown.append($0) }, b = Cold("b") { shown.append($0) }
        let focused = Cold("focused", focused: true) { shown.append($0) }
        // The frame's budget is spent: everything that comes now waits.
        #expect(scheduler.showNow(Cold("first") { shown.append($0) }))
        scheduler.setNeedsShowSelected(a)
        scheduler.setNeedsShowSelected(b)
        scheduler.setNeedsShowSelected(focused)
        #expect(shown == ["first"])
        frames.fire()
        #expect(shown == ["first", "focused"], "the focused pane waited behind \(shown.dropFirst()) for its surface")
        frames.fire()
        frames.fire()
        #expect(shown == ["first", "focused", "a", "b"], "the other panes are not shown one per frame in their order: \(shown)")
    }
}
