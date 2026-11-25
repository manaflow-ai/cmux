@testable import CmuxNextApp
import CmuxNextControl
import Testing

/// SPLIT OPEN CHAT (review of #40670): the presentation scheduler makes at most one new surface per display frame (a
/// new Ghostty surface compiles Metal pipelines on the main thread: 100 to 180 ms under load). A pane's show can ask
/// for ANOTHER pane's show in the same turn (`PaneController.showSelected` syncs a stale strip from the store; that
/// sync can apply the layout; the layout mounts a split's new pane, which shows with the layout change:
/// `showNow`). The frame's drain counted its surfaces in a local value and `showNow` read the value of the frame
/// BEFORE, so a `showNow` inside a drain did not see the drain's surface and the drain did not see its: two new
/// surfaces in one frame.
@MainActor @Suite(.serialized)
struct OneNewSurfacePerFrameTests {
    /// A pane whose selected content needs a new surface until it is shown; its show can do more work (`onShow`,
    /// before its own surface is made, as a stale strip's sync is).
    @MainActor final class Pane: PresentablePane {
        let name: String
        var onShow: () -> Void = {}
        private let made: (String) -> Void
        private(set) var selectedContentIsAlive: Bool
        private(set) var waits = 0
        let isFocusedInWorkspace = false
        init(_ name: String, alive: Bool = false, made: @escaping (String) -> Void) {
            (self.name, selectedContentIsAlive, self.made) = (name, alive, made)
        }
        func showSelected() {
            onShow()
            guard !selectedContentIsAlive else { return }
            selectedContentIsAlive = true
            made(name)
        }
        func showWhileWaiting() { waits += 1 }
    }

    /// Display frames the test runs one by one.
    final class Frames: ControlFrameSource, @unchecked Sendable { // touched on the main actor only
        nonisolated(unsafe) private var pending: [@MainActor @Sendable () -> Void] = [] // main actor only
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { pending.append(work) }
        @MainActor func fire() {
            let due = pending
            pending = []
            due.forEach { $0() }
        }
    }

    /// A pane that needs a surface is shown from the frame's queue, and its show asks for a second such pane's show
    /// (a split's new pane, mounted by the layout its stale strip applied): the second surface waits for the next frame.
    @Test func aShowInsideAColdPanesShowMakesNoSecondSurfaceInThatFrame() {
        var made: [String] = []
        let frames = Frames()
        let scheduler = ContentPresentationScheduler(frames: frames)
        let mounted = Pane("mounted") { made.append($0) }
        let first = Pane("first") { made.append($0) }
        var shownAtOnce: Bool?
        first.onShow = { shownAtOnce = scheduler.showNow(mounted) }
        scheduler.setNeedsShowSelected(first)
        // The surfaces each display frame makes.
        var perFrame: [[String]] = []
        for _ in 0..<3 {
            made = []
            frames.fire()
            perFrame.append(made)
        }
        #expect(perFrame.allSatisfy { $0.count <= 1 }, "a display frame made more than one new surface: \(perFrame)")
        #expect(perFrame.flatMap { $0 } == ["first", "mounted"], "each pane gets its surface, one frame after the other: \(perFrame)")
        #expect(shownAtOnce == false && mounted.waits == 1, "the pane that waits shows what it has (its last frame, its ground) in the frame that queued it: showNow answered \(String(describing: shownAtOnce)), \(mounted.waits) waiting shows")
    }

    /// The show that asks is of a pane whose content is alive (no surface): the pane it mounts takes the frame's one
    /// surface, with the layout change, and a pane that waited behind in the queue gets the next frame's.
    @Test func aShowInsideAnAlivePanesShowSpendsTheFramesOneSurface() {
        var made: [String] = []
        let frames = Frames()
        let scheduler = ContentPresentationScheduler(frames: frames)
        let mounted = Pane("mounted") { made.append($0) }
        let alive = Pane("alive", alive: true) { made.append($0) }
        let waiting = Pane("waiting") { made.append($0) }
        var shownAtOnce: Bool?
        alive.onShow = { if shownAtOnce == nil { shownAtOnce = scheduler.showNow(mounted) } }
        scheduler.setNeedsShowSelected(alive)
        scheduler.setNeedsShowSelected(waiting)
        // The surfaces each display frame makes.
        var perFrame: [[String]] = []
        for _ in 0..<3 {
            made = []
            frames.fire()
            perFrame.append(made)
        }
        #expect(perFrame.allSatisfy { $0.count <= 1 }, "a display frame made more than one new surface: \(perFrame)")
        #expect(perFrame.flatMap { $0 } == ["mounted", "waiting"], "the mounted pane shows with the layout change and the waiting pane a frame later: \(perFrame)")
        #expect(shownAtOnce == true, "a pane mounted by an alive pane's show is shown at once while the frame has its surface: \(String(describing: shownAtOnce))")
    }
}
