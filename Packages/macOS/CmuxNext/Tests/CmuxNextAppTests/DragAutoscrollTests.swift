import AppKit
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// A tab drag's edge auto-scroll of a columns screen (LayoutRootView+DragAutoscroll.swift): the
/// drag resolves the target once per pointer delivery and steps it once per frame with no hit test,
/// as Blink's AutoscrollController sets its target from the drag event and scrolls
/// it on the animation timer.
@MainActor
struct DragAutoscrollTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// Two full-width columns in a 1200 pt window: the strip scrolls one column's width.
    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init() {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([
                LayoutColumn(id: "c1", width: 1, root: .leaf("a")), LayoutColumn(id: "c2", width: 1, root: .leaf("b")),
            ]))], activeScreenID: "s", focusedPane: "a")
            model.followsDesignMetrics = false
            model.baseStyle.columnGap = 0
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
        }

        var view: ScreenContentView {
            get throws { try #require(root.screenViews["s"]) }
        }

        /// A point `inset` points inside the strip's trailing (or leading) edge, in window coordinates.
        func edgePoint(trailing: Bool, inset: CGFloat = 4) throws -> CGPoint {
            let view = try view
            let range = view.uncoveredRect
            return view.convert(CGPoint(x: trailing ? range.maxX - inset : range.minX + inset, y: range.midY), to: nil)
        }
    }

    @Test func theTrailingBandScrollsTowardTheTrailingEdgeEachFrame() throws {
        let screen = Screen()
        let view = try screen.view
        let autoscroll = try #require(screen.root.tabDragAutoscroll(locationInWindow: try screen.edgePoint(trailing: true)))
        #expect(autoscroll.screen == "s")
        #expect(autoscroll.speed > 0)
        var last = view.scroll.target
        for _ in 0..<4 {
            #expect(screen.root.stepTabDragAutoscroll(autoscroll, dt: 1.0 / 120), "a frame in the band did not scroll")
            #expect(view.scroll.target > last)
            last = view.scroll.target
        }
    }

    /// The speed grows toward the edge; the middle of the strip and the leading edge at rest ask
    /// for no scroll.
    @Test func theSpeedGrowsTowardTheEdgeAndTheMiddleAsksForNone() throws {
        let screen = Screen()
        let near = try #require(screen.root.tabDragAutoscroll(locationInWindow: try screen.edgePoint(trailing: true, inset: 2)))
        let far = try #require(screen.root.tabDragAutoscroll(locationInWindow: try screen.edgePoint(trailing: true, inset: 40)))
        #expect(near.speed > far.speed)
        let view = try screen.view
        let middle = view.convert(CGPoint(x: view.uncoveredRect.midX, y: view.uncoveredRect.midY), to: nil)
        #expect(screen.root.tabDragAutoscroll(locationInWindow: middle) == nil)
        // At offset 0 the leading band resolves a target, but a step cannot move past the start.
        let leading = try #require(screen.root.tabDragAutoscroll(locationInWindow: try screen.edgePoint(trailing: false)))
        #expect(leading.speed < 0)
        #expect(!screen.root.stepTabDragAutoscroll(leading, dt: 1.0 / 120))
    }

    /// A target resolved on one screen does not scroll another: the drag hit-tests again first.
    @Test func aTargetOfAScreenNoLongerActiveDoesNotScroll() throws {
        let screen = Screen()
        let autoscroll = TabDragAutoscroll(screen: "gone", speed: 1_400)
        #expect(!screen.root.stepTabDragAutoscroll(autoscroll, dt: 1.0 / 120))
        #expect(try screen.view.scroll.target == 0)
    }
}
