import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// Lawrence (2026-10-23): splits lag, more with Chromium pages. While a page window shows, every
/// divider hit area has a click-catching panel above the pages (`DividerMouseCatchers`). Each
/// frame of a split, close, zoom or New Column moved the dividers, so each frame moved every moving
/// divider's panel (one window server move each, a new panel for a new divider) and re-ran divider
/// hover: at 30 panes 64 % of `advanceFrame` (PL-motion-core profile, cmux10s, b553d0648b1). Nobody
/// grabs a divider on a spring: the window's catcher areas, which every panel follows, change once
/// when the layout lands and never during the motion.
@MainActor @Suite(.serialized) struct DividerCatcherMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// A shell window whose content is a layout of two side-by-side panes, its overlay layer
    /// adopting the layout's plane, as the app wires them; the test drives the frames.
    struct Layout {
        let window: ShellWindow
        let model: LayoutModel
        let root: LayoutRootView
        let provider = Panes()

        init() {
            _ = NSApplication.shared
            let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b")))
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))], activeScreenID: "s", focusedPane: "a")
            model.followsDesignMetrics = false
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
            settle()
        }

        @discardableResult
        func settle() -> Int {
            var frames = 0
            while frames < 480, root.advanceFrame(1.0 / 120) { frames += 1 }
            return frames
        }

        var catcherAreas: [CGRect] { window.overlayLayer.catcherAreas.map(\.rect) }
        var dividerAreas: [CGRect] { window.overlayLayer.dividerAreas.map(\.rect) }
    }

    @Test func aSplitMovesNoCatcherAreaUntilItLands() throws {
        let layout = Layout()
        defer { layout.window.close() }
        let before = layout.catcherAreas
        try #require(!before.isEmpty, "the split's divider has a catcher area: \(layout.window.overlayLayer.dividerAreas)")

        // A third pane splits off the right one: the existing divider springs left, a new one grows in.
        let column = LayoutColumn(id: "c", width: 1, root: .split("s", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("a"),
                                                                    b: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: .leaf("c"))))
        layout.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))])
        layout.root.syncWithModel()

        var springFrames = 0, catcherChangesInMotion = 0, dividerChangesInMotion = 0
        var lastCatchers = layout.catcherAreas, lastDividers = layout.dividerAreas
        while springFrames < 480, layout.root.advanceFrame(1.0 / 120) {
            springFrames += 1
            if layout.catcherAreas != lastCatchers { catcherChangesInMotion += 1 }
            if layout.dividerAreas != lastDividers { dividerChangesInMotion += 1 }
            (lastCatchers, lastDividers) = (layout.catcherAreas, layout.dividerAreas)
        }
        try #require(springFrames > 4 && dividerChangesInMotion > 4, "the split animated: \(springFrames) frames, dividers moved \(dividerChangesInMotion)")
        // The frame the spring landed in returned false: the catchers follow there, once.
        #expect(catcherChangesInMotion <= 1, "catcher areas changed on \(catcherChangesInMotion) of \(springFrames) spring frames")
        #expect(layout.catcherAreas == layout.dividerAreas, "at rest the catchers cover the dividers: \(layout.catcherAreas) vs \(layout.dividerAreas)")
        #expect(layout.catcherAreas.count == before.count + 1, "the new split's divider has its area at rest: \(before) -> \(layout.catcherAreas)")
    }

    /// What one divider drag event costs the layout and the window (`LayoutWorkProbe`), for a split divider and a
    /// column edge in a strip beside a right dock: each event's model writes and syncs, geometry computes
    /// (reconciles), presentation passes, pane chrome updates, host frames, strip clips and ring masks, catcher
    /// area changes, page update requests and display link starts. A drag moves its panes in the event's own
    /// turn, writes the model once (on release), and leaves the catcher panels where they are until it lands.
    @Test func dividerDragWorkPerEvent() async throws {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "c0", width: 0.4, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))),
            LayoutColumn(id: "c1", width: 0.4, root: .split("y", axis: .vertical, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4"))),
            LayoutColumn(id: "c2", width: 0.4, root: .leaf("p5")),
            LayoutColumn(id: "dock", width: 0.25, root: .leaf("chat"), dock: DockColumn(edge: .right, mode: .docked)),
        ])
        for kind in [DividerHandleView.Kind.split("x"), .columnEdge("c0")] {
            let probe = LayoutWorkProbe(layout, focused: "p1")
            defer { probe.close() }
            let handle = try #require(probe.screen.dividerViews[kind], "no handle \(kind)")
            let start = probe.screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil)
            _ = await probe.measure { handle.mouseDown(with: probe.event(.leftMouseDown, start)) }
            var moves = LayoutWorkProbe.Counts()
            // 60 display frames of 4 drag events each (a fast mouse sends several per frame): the frame's first event
            // lays out in its turn, the rest show once at the frame's tick (`displayFrameBegan`).
            let steps = 60, perFrame = 4
            var point = start
            for step in 1...steps {
                moves = moves + (await probe.measure(tick: true) {
                    for sub in 1...perFrame {
                        let t = (Double(step - 1) + Double(sub) / Double(perFrame)) / Double(steps)
                        point = CGPoint(x: start.x + 80 * CGFloat(sin(t * 2 * .pi)), y: start.y)
                        handle.mouseDragged(with: probe.event(.leftMouseDragged, point))
                    }
                })
            }
            // A still pointer: the drag keeps the ticks a short tail (`panTickTail`), then none.
            let still = probe.settle()
            let release = await probe.measure { handle.mouseUp(with: probe.event(.leftMouseUp, point)) }
            probe.settle()
            let name = if case .split = kind { "split" } else { "column" }
            print(moves.line("drag-\(name)-move", steps: steps * perFrame))
            print(release.line("drag-\(name)-release", steps: 1))
            print("drag-\(name)-still frames=\(still)")
            #expect(moves.modelWrites == 0, "\(name): \(moves.modelWrites) model writes over \(steps * perFrame) moves")
            #expect(moves.reconciles <= 2 * steps, "\(name): \(moves.reconciles) layout passes over \(steps) frames of \(perFrame) moves")
            #expect(moves.presentations <= 2 * steps, "\(name): \(moves.presentations) presentation passes over \(steps) frames")
            #expect(moves.catcherChanges == 0, "\(name): the catcher areas moved on \(moves.catcherChanges) of \(steps) frames")
            #expect(still <= ScreenContentView.panTickTail, "\(name): \(still) frame ticks with the pointer still")
            #expect(probe.window.overlayLayer.catcherAreas == probe.window.overlayLayer.dividerAreas,
                    "\(name): at rest the catchers cover the dividers")
        }
    }
}
