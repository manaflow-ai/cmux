import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The sidebar's slide resizes the screen under a running pane spring (a divider on its way to another ratio: an
/// equalize, a width preset, another client's drag). Each frame of that resize must reach the panes in the same frame:
/// a frame on a spring moves with its target and keeps only what it had left to travel, instead of chasing a target
/// that moved under it. A split, a close and a zoom leave no spring to carry: each is one commit, and a resize after
/// it finds every pane at rest.
@MainActor
@Suite(.closesItsWindows)
struct ViewportResizeMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// p1 | p2 with their divider at `ratio`.
    static func pair(_ ratio: Double) -> ScreenLayout {
        .splits(.split("h", axis: .horizontal, ratio: ratio, a: .leaf("p1"), b: .leaf("p2")))
    }

    final class Screen {
        let panes = Panes()
        let context: LayoutViewContext
        let view: ScreenContentView
        let window: NSWindow

        init() {
            let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: ViewportResizeMotionTests.pair(0.5))],
                                    activeScreenID: "s", focusedPane: "p1")
            context = LayoutViewContext(model: model, provider: panes)
            context.reduceMotionOverride = false
            context.livePanes = ["p1", "p2"]
            view = ScreenContentView(screenID: "s", layout: ViewportResizeMotionTests.pair(0.5), context: context)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = view
            view.reconcile(animated: false)
        }

        /// The divider goes from the middle to 30 % on a spring: no pane comes or goes, so both panes' frames spring.
        func moveDivider() {
            view.update(layout: ViewportResizeMotionTests.pair(0.3), animated: true)
        }

        @discardableResult
        func step() -> Bool { view.step(1.0 / 120) }
    }

    /// Where each edge still has to go: target minus shown.
    static func left(_ frame: AnimatedFrame) -> [CGFloat] {
        let (rect, target) = (frame.rect, frame.targetRect)
        return [target.minX - rect.minX, target.minY - rect.minY, target.width - rect.width, target.height - rect.height]
    }

    /// A frame of the sidebar's slide while the divider is on its way: each pane keeps what it had left to travel and
    /// its velocity, on a target that moved with the screen's edge.
    @Test func aSidebarSlideFrameReachesTheSpringingPanesInTheSameFrame() throws {
        let screen = Screen()
        screen.moveDivider()
        for _ in 0..<4 { screen.step() }
        let before = try #require(screen.view.paneFrames["p1"])
        let otherBefore = try #require(screen.view.paneFrames["p2"])
        #expect(before.rect != before.targetRect, "the spring landed before the slide frame: nothing to carry")

        // One frame of the sidebar's slide: the screen loses 40 pt.
        screen.view.setFrameSize(NSSize(width: 1160, height: 800))

        let after = try #require(screen.view.paneFrames["p1"])
        let otherAfter = try #require(screen.view.paneFrames["p2"])
        #expect(after.targetRect.width < before.targetRect.width, "the resize did not move the main pane's target")
        for (was, now) in zip(Self.left(before), Self.left(after)) {
            #expect(abs(was - now) < 0.01, "the main pane chases its moved target: \(Self.left(before)) left before, \(Self.left(after)) after")
        }
        for (was, now) in zip(Self.left(otherBefore), Self.left(otherAfter)) {
            #expect(abs(was - now) < 0.01,
                    "the other pane chases its moved target: \(Self.left(otherBefore)) left before, \(Self.left(otherAfter)) after")
        }
        #expect(after.x.velocity == before.x.velocity && after.width.velocity == before.width.velocity, "the carry changed the spring's velocity")
    }

    /// The spring that a slide frame carried goes on to the places the new size gives the panes, and stops there.
    @Test func theCarriedSpringStillLandsWhereTheNewSizePutsIt() throws {
        let screen = Screen()
        screen.moveDivider()
        for _ in 0..<4 { screen.step() }
        screen.view.setFrameSize(NSSize(width: 1160, height: 800))
        for _ in 0..<240 where screen.step() {}
        #expect(screen.view.paneFrames["p1"]?.rect == screen.view.geometry.panes["p1"])
        #expect(screen.view.paneFrames["p2"]?.rect == screen.view.geometry.panes["p2"])
        #expect(!screen.step(), "the carried spring kept asking for frames")
    }

    @Test func aResizeAtRestStillSnaps() throws {
        let screen = Screen()
        screen.moveDivider()
        for _ in 0..<240 where screen.step() {}
        screen.view.setFrameSize(NSSize(width: 1160, height: 800))
        #expect(screen.view.paneFrames["p1"]?.rect == screen.view.geometry.panes["p1"])
        #expect(!screen.view.hasMotion)
    }
}
