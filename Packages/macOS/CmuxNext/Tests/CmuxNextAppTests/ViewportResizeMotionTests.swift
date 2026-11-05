import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The sidebar's slide resizes the screen under a running split (Leo 2026-11-05, Cmd-B then Cmd-D: "the right pane shifts
/// and then the main pane waits for the right pane to shift before it shifts"). Each frame of that resize must reach the
/// panes in the same frame: a frame on a spring moves with its target and keeps only what it had left to travel, instead
/// of chasing a target that moved under it.
@MainActor
@Suite(.closesItsWindows)
struct ViewportResizeMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Screen {
        let panes = Panes()
        let context: LayoutViewContext
        let view: ScreenContentView
        let window: NSWindow

        init() {
            let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))],
                                    activeScreenID: "s", focusedPane: "p1")
            context = LayoutViewContext(model: model, provider: panes)
            context.reduceMotionOverride = false
            context.livePanes = ["p1"]
            view = ScreenContentView(screenID: "s", layout: .splits(.leaf("p1")), context: context)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = view
            view.reconcile(animated: false)
        }

        func splitRight() {
            context.livePanes = ["p1", "p2"]
            view.update(layout: .splits(.split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))), animated: true)
        }

        @discardableResult
        func step() -> Bool { view.step(1.0 / 120) }
    }

    /// Where each edge still has to go: target minus shown.
    static func left(_ frame: AnimatedFrame) -> [CGFloat] {
        let (rect, target) = (frame.rect, frame.targetRect)
        return [target.minX - rect.minX, target.minY - rect.minY, target.width - rect.width, target.height - rect.height]
    }

    @Test func aSidebarSlideFrameReachesTheSplittingPanesInTheSameFrame() throws {
        let screen = Screen()
        screen.splitRight()
        for _ in 0..<4 { screen.step() }
        let before = try #require(screen.view.paneFrames["p1"])
        let newBefore = try #require(screen.view.paneFrames["p2"])
        #expect(before.rect != before.targetRect, "the split landed before the slide frame: nothing to carry")

        // One frame of the sidebar's slide: the screen loses 40 pt.
        screen.view.setFrameSize(NSSize(width: 1160, height: 800))

        let after = try #require(screen.view.paneFrames["p1"])
        let newAfter = try #require(screen.view.paneFrames["p2"])
        #expect(after.targetRect.width < before.targetRect.width, "the resize did not move the main pane's target")
        for (was, now) in zip(Self.left(before), Self.left(after)) {
            #expect(abs(was - now) < 0.01, "the main pane chases its moved target: \(Self.left(before)) left before, \(Self.left(after)) after")
        }
        for (was, now) in zip(Self.left(newBefore), Self.left(newAfter)) {
            #expect(abs(was - now) < 0.01, "the new pane chases its moved target: \(Self.left(newBefore)) left before, \(Self.left(newAfter)) after")
        }
        #expect(after.x.velocity == before.x.velocity && after.width.velocity == before.width.velocity, "the carry changed the spring's velocity")
    }

    @Test func theCarriedSplitStillLandsWhereTheNewSizePutsIt() throws {
        let screen = Screen()
        screen.splitRight()
        for _ in 0..<4 { screen.step() }
        screen.view.setFrameSize(NSSize(width: 1160, height: 800))
        for _ in 0..<240 where screen.step() {}
        #expect(screen.view.paneFrames["p1"]?.rect == screen.view.geometry.panes["p1"])
        #expect(screen.view.paneFrames["p2"]?.rect == screen.view.geometry.panes["p2"])
        #expect(!screen.step(), "the carried split kept asking for frames")
    }

    @Test func aResizeAtRestStillSnaps() throws {
        let screen = Screen()
        screen.splitRight()
        for _ in 0..<240 where screen.step() {}
        screen.view.setFrameSize(NSSize(width: 1160, height: 800))
        #expect(screen.view.paneFrames["p1"]?.rect == screen.view.geometry.panes["p1"])
        #expect(!screen.view.hasMotion)
    }
}
